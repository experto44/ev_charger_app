import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Charging-expenses log — the money side of owning the car.
///
/// The driver records what a charge cost them:
///   • a paid charge — they type the amount they paid in the provider's own app;
///   • a home charge — they type the battery percentage they started and ended
///     at, and we work the cost out from their own tariff.
///
/// Storage is "Firestore + local cache": the on-device JSON is what the screen
/// renders (so the list is there instantly, and works signed out), and
/// `users/{uid}/expenses/{id}` is the copy that follows the account to another
/// phone. [sync] reconciles the two.
///
/// Singleton: use [ExpensesService.I].

// ── Model ─────────────────────────────────────────────────────────────────────

enum ChargeKind { paid, home }

/// One recorded charge.
///
/// Home entries carry the settings they were computed with ([batteryKwh],
/// [tariff], [lossPercent]) rather than only the percentages. Recomputing from
/// today's settings would rewrite history the moment the driver changes car or
/// the tariff goes up, so the numbers are stamped in at save time and never
/// derived again.
class ExpenseEntry {
  const ExpenseEntry({
    required this.id,
    required this.date,
    required this.kind,
    required this.amount,
    required this.updatedAt,
    this.fromPercent,
    this.toPercent,
    this.batteryKwh,
    this.tariff,
    this.lossPercent,
    this.kwh,
    this.dirty = false,
  });

  /// Document id, also the local list key. Generated on the device.
  final String id;

  /// The day the charge happened (local midnight — no time of day is asked for).
  final DateTime date;

  final ChargeKind kind;

  /// What it cost, in GEL. Typed by the driver for a paid charge, computed for
  /// a home one.
  final double amount;

  /// Epoch ms of the last local edit. Drives last-write-wins in [sync].
  final int updatedAt;

  // ── Home-charge stamps (null on paid entries) ───────────────────────────────
  final int?    fromPercent;
  final int?    toPercent;
  final double? batteryKwh;
  final double? tariff;
  final double? lossPercent;

  /// Energy taken from the meter, kWh — i.e. including the charging loss.
  final double? kwh;

  /// Local-only: this entry has not been written to Firestore yet. Never
  /// travels to the server.
  final bool dirty;

  bool get isHome => kind == ChargeKind.home;

  ExpenseEntry copyWith({bool? dirty, int? updatedAt}) => ExpenseEntry(
        id:          id,
        date:        date,
        kind:        kind,
        amount:      amount,
        updatedAt:   updatedAt ?? this.updatedAt,
        fromPercent: fromPercent,
        toPercent:   toPercent,
        batteryKwh:  batteryKwh,
        tariff:      tariff,
        lossPercent: lossPercent,
        kwh:         kwh,
        dirty:       dirty ?? this.dirty,
      );

  /// Firestore shape. `dirty` is deliberately absent — it is a local flag.
  Map<String, dynamic> toMap() => <String, dynamic>{
        'date':        Timestamp.fromDate(date),
        'kind':        isHome ? 'home' : 'paid',
        'amount':      amount,
        'updatedAt':   updatedAt,
        if (fromPercent != null) 'fromPercent': fromPercent,
        if (toPercent   != null) 'toPercent':   toPercent,
        if (batteryKwh  != null) 'batteryKwh':  batteryKwh,
        if (tariff      != null) 'tariff':      tariff,
        if (lossPercent != null) 'lossPercent': lossPercent,
        if (kwh         != null) 'kwh':         kwh,
      };

  static ExpenseEntry? fromMap(String id, Map<String, dynamic> m) {
    final rawDate = m['date'];
    DateTime? date;
    if (rawDate is Timestamp)  { date = rawDate.toDate(); }
    if (rawDate is int)        { date = DateTime.fromMillisecondsSinceEpoch(rawDate); }
    if (rawDate is String)     { date = DateTime.tryParse(rawDate); }
    final amount = _toDouble(m['amount']);
    if (date == null || amount == null) { return null; }
    return ExpenseEntry(
      id:          id,
      date:        DateTime(date.year, date.month, date.day),
      kind:        m['kind'] == 'home' ? ChargeKind.home : ChargeKind.paid,
      amount:      amount,
      updatedAt:   m['updatedAt'] is int
          ? m['updatedAt'] as int
          : date.millisecondsSinceEpoch,
      fromPercent: _toInt(m['fromPercent']),
      toPercent:   _toInt(m['toPercent']),
      batteryKwh:  _toDouble(m['batteryKwh']),
      tariff:      _toDouble(m['tariff']),
      lossPercent: _toDouble(m['lossPercent']),
      kwh:         _toDouble(m['kwh']),
    );
  }

  /// Local cache shape — plain JSON, so dates go as epoch ms and the local-only
  /// [dirty] flag rides along.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id':          id,
        'date':        date.millisecondsSinceEpoch,
        'kind':        isHome ? 'home' : 'paid',
        'amount':      amount,
        'updatedAt':   updatedAt,
        'fromPercent': fromPercent,
        'toPercent':   toPercent,
        'batteryKwh':  batteryKwh,
        'tariff':      tariff,
        'lossPercent': lossPercent,
        'kwh':         kwh,
        'dirty':       dirty,
      };

  static ExpenseEntry? fromJson(Map<String, dynamic> j) {
    final id     = j['id'];
    final amount = _toDouble(j['amount']);
    final ms     = _toInt(j['date']);
    if (id is! String || id.isEmpty || amount == null || ms == null) {
      return null;
    }
    final date = DateTime.fromMillisecondsSinceEpoch(ms);
    return ExpenseEntry(
      id:          id,
      date:        DateTime(date.year, date.month, date.day),
      kind:        j['kind'] == 'home' ? ChargeKind.home : ChargeKind.paid,
      amount:      amount,
      updatedAt:   _toInt(j['updatedAt']) ?? ms,
      fromPercent: _toInt(j['fromPercent']),
      toPercent:   _toInt(j['toPercent']),
      batteryKwh:  _toDouble(j['batteryKwh']),
      tariff:      _toDouble(j['tariff']),
      lossPercent: _toDouble(j['lossPercent']),
      kwh:         _toDouble(j['kwh']),
      dirty:       j['dirty'] == true,
    );
  }
}

double? _toDouble(Object? v) {
  if (v is num)    { return v.toDouble(); }
  if (v is String) { return double.tryParse(v); }
  return null;
}

int? _toInt(Object? v) {
  if (v is int)    { return v; }
  if (v is num)    { return v.round(); }
  if (v is String) { return int.tryParse(v); }
  return null;
}

/// What a home charge costs the driver: their battery, their tariff, and how
/// much of the metered energy never reaches the battery.
class ExpenseSettings {
  const ExpenseSettings({
    this.batteryKwh,
    this.tariff,
    this.lossPercent = kDefaultLossPercent,
  });

  /// AC charging really does lose 8-12% between the meter and the cells, so a
  /// home charge costs more than `battery × Δ% × tariff`. 10% is the default;
  /// the driver can change it.
  static const double kDefaultLossPercent = 10;

  /// Usable battery capacity in kWh.
  final double? batteryKwh;

  /// Household electricity price in GEL per kWh.
  final double? tariff;

  /// Percentage of metered energy lost to charging, 0-50.
  final double lossPercent;

  /// A home charge can only be costed once both numbers are known.
  bool get isComplete =>
      (batteryKwh ?? 0) > 0 && (tariff ?? 0) > 0;

  /// Energy pulled from the meter to move the battery from [from]% to [to]%,
  /// in kWh — the loss is what makes this bigger than the battery's own gain.
  double? kwhFor(int from, int to) {
    final cap = batteryKwh;
    if (cap == null || cap <= 0 || to <= from) { return null; }
    final intoBattery = cap * (to - from) / 100.0;
    final efficiency  = 1 - (lossPercent.clamp(0, 50) / 100.0);
    return intoBattery / efficiency;
  }

  /// What that charge costs, in GEL.
  double? costFor(int from, int to) {
    final energy = kwhFor(from, to);
    final price  = tariff;
    if (energy == null || price == null || price <= 0) { return null; }
    return energy * price;
  }
}

// ── Service ───────────────────────────────────────────────────────────────────

class ExpensesService {
  ExpensesService._();
  static final ExpensesService I = ExpensesService._();

  /// Cache keys are scoped to the account, so signing in as somebody else can
  /// never show them the previous user's spending. Entries recorded while
  /// signed out live under [_localScope] until an account adopts them.
  static const String _localScope   = 'local';
  static const String _entriesKey   = 'expenses_entries_v1';
  static const String _deletesKey   = 'expenses_deletes_v1';
  static const String _settingsKey  = 'expenses_settings_v1';

  FirebaseFirestore get _db => FirebaseFirestore.instance;

  /// The signed-in account, or null. Reaching for [FirebaseAuth] throws when no
  /// Firebase app exists at all (widget tests), and a log of charges is exactly
  /// the kind of screen that should still work in that case: no account simply
  /// means the local scope and no syncing.
  User? get _user {
    try {
      return FirebaseAuth.instance.currentUser;
    } catch (_) {
      return null;
    }
  }

  /// Bumped after any change, so open screens can rebuild.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  final List<ExpenseEntry> _entries = <ExpenseEntry>[];

  /// Ids deleted locally that Firestore has not confirmed yet. Kept so a delete
  /// made offline is not undone by the next sync handing the entry back.
  final Set<String> _pendingDeletes = <String>{};

  ExpenseSettings _settings = const ExpenseSettings();

  /// Scope the in-memory list currently belongs to (uid, or [_localScope]).
  String _scope = _localScope;

  bool _loaded = false;

  /// Newest first — the order the list is shown in.
  List<ExpenseEntry> get entries {
    final list = List<ExpenseEntry>.from(_entries);
    list.sort((a, b) {
      final byDate = b.date.compareTo(a.date);
      return byDate != 0 ? byDate : b.updatedAt.compareTo(a.updatedAt);
    });
    return list;
  }

  ExpenseSettings get settings => _settings;
  bool get isSignedIn => _user != null;
  bool get isLoaded => _loaded;

  String get _currentScope => _user?.uid ?? _localScope;

  CollectionReference<Map<String, dynamic>>? get _remote {
    final uid = _user?.uid;
    if (uid == null) { return null; }
    return _db.collection('users').doc(uid).collection('expenses');
  }

  // ── Loading ────────────────────────────────────────────────────────────────

  /// Reads the cache for whoever is signed in now and, when that is an account,
  /// reconciles it with Firestore. Safe to call on every screen open: it also
  /// re-scopes after a sign-in, sign-out or account switch.
  Future<void> load({bool sync = true}) async {
    final scope = _currentScope;
    final prefs = await SharedPreferences.getInstance();

    _scope = scope;
    _entries
      ..clear()
      ..addAll(_readEntries(prefs, scope));
    _pendingDeletes
      ..clear()
      ..addAll(prefs.getStringList('${_deletesKey}_$scope') ?? const <String>[]);
    _settings = _readSettings(prefs);
    _loaded = true;
    _bump();

    // Entries recorded before signing in belong to the person who typed them,
    // so the first account to open the screen adopts them (and the anonymous
    // scope is emptied, which is what stops them reaching a second account).
    if (scope != _localScope) {
      final orphans = _readEntries(prefs, _localScope);
      if (orphans.isNotEmpty) {
        for (final e in orphans) {
          if (_entries.any((x) => x.id == e.id)) { continue; }
          _entries.add(e.copyWith(dirty: true));
        }
        await prefs.remove('${_entriesKey}_$_localScope');
        await prefs.remove('${_deletesKey}_$_localScope');
        await _persist();
        _bump();
      }
    }

    if (sync) { await this.sync(); }
  }

  List<ExpenseEntry> _readEntries(SharedPreferences prefs, String scope) {
    final raw = prefs.getString('${_entriesKey}_$scope');
    if (raw == null || raw.isEmpty) { return <ExpenseEntry>[]; }
    try {
      final list = jsonDecode(raw);
      if (list is! List) { return <ExpenseEntry>[]; }
      return list
          .whereType<Map<String, dynamic>>()
          .map(ExpenseEntry.fromJson)
          .whereType<ExpenseEntry>()
          .toList();
    } catch (_) {
      return <ExpenseEntry>[];
    }
  }

  ExpenseSettings _readSettings(SharedPreferences prefs) {
    final raw = prefs.getString(_settingsKey);
    if (raw == null || raw.isEmpty) { return const ExpenseSettings(); }
    try {
      final m = jsonDecode(raw);
      if (m is! Map) { return const ExpenseSettings(); }
      return ExpenseSettings(
        batteryKwh:  _toDouble(m['batteryKwh']),
        tariff:      _toDouble(m['tariff']),
        lossPercent: _toDouble(m['lossPercent'])
            ?? ExpenseSettings.kDefaultLossPercent,
      );
    } catch (_) {
      return const ExpenseSettings();
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '${_entriesKey}_$_scope',
      jsonEncode(_entries.map((e) => e.toJson()).toList()),
    );
    await prefs.setStringList(
      '${_deletesKey}_$_scope',
      _pendingDeletes.toList(),
    );
  }

  void _bump() => revision.value++;

  // ── Settings ───────────────────────────────────────────────────────────────

  Future<void> saveSettings(ExpenseSettings s) async {
    _settings = s;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_settingsKey, jsonEncode(<String, dynamic>{
      'batteryKwh':  s.batteryKwh,
      'tariff':      s.tariff,
      'lossPercent': s.lossPercent,
    }));
    _bump();

    // Mirrored onto the account so a new phone starts with the driver's own
    // numbers instead of an empty form. Best-effort — the device copy is what
    // the screen reads.
    final uid = _user?.uid;
    if (uid == null) { return; }
    try {
      await _db.collection('users').doc(uid).set(<String, dynamic>{
        'expenseSettings': <String, dynamic>{
          'batteryKwh':  s.batteryKwh,
          'tariff':      s.tariff,
          'lossPercent': s.lossPercent,
        },
      }, SetOptions(merge: true)).timeout(const Duration(seconds: 8));
    } catch (_) {/* offline or denied — local settings still stand */}
  }

  /// Pulls the account's settings when this device has none of its own.
  Future<void> _pullSettingsIfEmpty() async {
    if (_settings.isComplete) { return; }
    final uid = _user?.uid;
    if (uid == null) { return; }
    try {
      final snap = await _db.collection('users').doc(uid).get()
          .timeout(const Duration(seconds: 8));
      final m = snap.data()?['expenseSettings'];
      if (m is! Map) { return; }
      final pulled = ExpenseSettings(
        batteryKwh:  _toDouble(m['batteryKwh']),
        tariff:      _toDouble(m['tariff']),
        lossPercent: _toDouble(m['lossPercent'])
            ?? ExpenseSettings.kDefaultLossPercent,
      );
      if (!pulled.isComplete) { return; }
      _settings = pulled;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_settingsKey, jsonEncode(<String, dynamic>{
        'batteryKwh':  pulled.batteryKwh,
        'tariff':      pulled.tariff,
        'lossPercent': pulled.lossPercent,
      }));
      _bump();
    } catch (_) {/* best-effort */}
  }

  // ── Records ────────────────────────────────────────────────────────────────

  /// Ids are generated here so an entry exists (and shows) before any network
  /// call: time-ordered prefix plus randomness, which keeps two devices adding
  /// entries in the same second from colliding.
  static String newId() {
    final now  = DateTime.now().millisecondsSinceEpoch;
    final rand = math.Random().nextInt(0x7fffffff).toRadixString(36);
    return '${now.toRadixString(36)}$rand';
  }

  /// Adds or replaces an entry. Writes the cache first, then pushes.
  Future<void> upsert(ExpenseEntry entry) async {
    final e = entry.copyWith(
      dirty: true,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final i = _entries.indexWhere((x) => x.id == e.id);
    if (i == -1) { _entries.add(e); } else { _entries[i] = e; }
    _pendingDeletes.remove(e.id);
    await _persist();
    _bump();
    await _push(e);
  }

  Future<void> remove(String id) async {
    _entries.removeWhere((x) => x.id == id);
    _pendingDeletes.add(id);
    await _persist();
    _bump();

    final remote = _remote;
    if (remote == null) {
      // Signed out: nothing on the server to delete, and the id must not linger
      // as a tombstone that would delete a future entry with the same id.
      _pendingDeletes.remove(id);
      await _persist();
      return;
    }
    final scope = _scope;
    try {
      await remote.doc(id).delete().timeout(const Duration(seconds: 8));
      if (_scope != scope) { return; }
      _pendingDeletes.remove(id);
      await _persist();
    } catch (_) {/* retried by the next sync */}
  }

  Future<void> _push(ExpenseEntry e) async {
    final remote = _remote;
    if (remote == null) { return; }
    final scope = _scope;
    try {
      await remote.doc(e.id).set(e.toMap()).timeout(const Duration(seconds: 8));
      if (_scope != scope) { return; }
      final i = _entries.indexWhere((x) => x.id == e.id);
      // Only clear the flag if the entry has not been edited again meanwhile.
      if (i != -1 && _entries[i].updatedAt == e.updatedAt) {
        _entries[i] = _entries[i].copyWith(dirty: false);
        await _persist();
      }
    } catch (_) {/* stays dirty, retried by the next sync */}
  }

  // ── Sync ───────────────────────────────────────────────────────────────────

  /// Two-way reconciliation with `users/{uid}/expenses`:
  ///   • pending deletes are replayed against the server;
  ///   • entries only this device has (dirty) are uploaded;
  ///   • entries only the server has are pulled down;
  ///   • entries the server no longer has were deleted on another device.
  ///
  /// The decisions themselves live in [planSync], which is pure and tested; this
  /// method only does the talking to Firestore.
  Future<void> sync() async {
    final remote = _remote;
    if (remote == null) { return; }

    // Whose list this sync is for. A sign-out (or a switch of account) while
    // the network call is in flight must not write one user's entries into
    // another's cache, so every step below bails out if the scope moved.
    final scope = _scope;

    await _pullSettingsIfEmpty();

    // Stamped BEFORE the fetch: anything the driver records while this sync is
    // in flight is newer than what the server was asked about, so its absence
    // from the answer means nothing.
    final fetchedAt = DateTime.now().millisecondsSinceEpoch;

    QuerySnapshot<Map<String, dynamic>> snap;
    try {
      snap = await remote.get().timeout(const Duration(seconds: 12));
    } catch (_) {
      return; // offline — the cache is already on screen, try again next open
    }
    if (_scope != scope) { return; }

    final remoteById = <String, ExpenseEntry>{};
    for (final doc in snap.docs) {
      final e = ExpenseEntry.fromMap(doc.id, doc.data());
      if (e != null) { remoteById[doc.id] = e; }
    }

    // Replay deletes first, and drop them from the server picture as they go —
    // otherwise the entry we just deleted is read back as "new here" below.
    for (final id in _pendingDeletes.toList()) {
      try {
        await remote.doc(id).delete().timeout(const Duration(seconds: 8));
        if (_scope != scope) { return; }
        _pendingDeletes.remove(id);
        remoteById.remove(id);
      } catch (_) {/* keep it pending */}
    }

    final plan = planSync(
      local:          _entries,
      remote:         remoteById,
      pendingDeletes: _pendingDeletes,
      serverAnswered: !snap.metadata.isFromCache,
      fetchedAt:      fetchedAt,
    );

    var changed = false;

    for (final entry in plan.upload) {
      try {
        await remote.doc(entry.id).set(entry.toMap())
            .timeout(const Duration(seconds: 8));
        if (_scope != scope) { return; }
        final i = _entries.indexWhere((x) => x.id == entry.id);
        // Only clear the flag if the entry has not been edited again meanwhile.
        if (i != -1 && _entries[i].updatedAt == entry.updatedAt) {
          _entries[i] = _entries[i].copyWith(dirty: false);
          changed = true;
        }
      } catch (_) {/* stays dirty, retried by the next sync */}
    }

    for (final entry in plan.adopt) {
      final i = _entries.indexWhere((x) => x.id == entry.id);
      if (i == -1) { _entries.add(entry); } else { _entries[i] = entry; }
      changed = true;
    }

    if (plan.dropLocally.isNotEmpty) {
      _entries.removeWhere((e) => plan.dropLocally.contains(e.id));
      changed = true;
    }

    await _persist();
    if (changed) { _bump(); }
  }

  /// Works out what a sync should do, given what this device holds and what the
  /// server just said. Pure, so the awkward cases (an entry recorded while the
  /// sync was in flight, one deleted on another phone, one that has never
  /// reached the server) can be tested without Firestore.
  ///
  /// [serverAnswered] must be false when the snapshot came from Firestore's
  /// offline cache: an entry missing from a cache read proves nothing about
  /// whether it still exists. [fetchedAt] is the moment the read was issued.
  static ExpensesSyncPlan planSync({
    required List<ExpenseEntry> local,
    required Map<String, ExpenseEntry> remote,
    required Set<String> pendingDeletes,
    required bool serverAnswered,
    required int fetchedAt,
  }) {
    final upload = <ExpenseEntry>[];
    final adopt  = <ExpenseEntry>[];
    final drop   = <String>[];

    for (final e in local) {
      final r = remote[e.id];
      if (r != null && r.updatedAt > e.updatedAt) {
        adopt.add(r);              // edited more recently on another device
        continue;
      }
      if (e.dirty) {
        upload.add(e);             // never reached the server, or changed here
        continue;
      }
      // Clean and gone from the server: deleted on another device. Only trust
      // that when the server actually answered, and never for an entry written
      // after this sync asked its question.
      if (r == null && serverAnswered && e.updatedAt < fetchedAt) {
        drop.add(e.id);
      }
    }

    final localIds = local.map((e) => e.id).toSet();
    for (final r in remote.values) {
      if (localIds.contains(r.id)) { continue; }
      if (pendingDeletes.contains(r.id)) { continue; }
      adopt.add(r);                // recorded on another device
    }

    return ExpensesSyncPlan(upload: upload, adopt: adopt, dropLocally: drop);
  }

  // ── Totals for the summary card ────────────────────────────────────────────

  double get totalAll =>
      _entries.fold<double>(0, (acc, e) => acc + e.amount);

  double totalForMonth(DateTime month) => _entries
      .where((e) => e.date.year == month.year && e.date.month == month.month)
      .fold<double>(0, (acc, e) => acc + e.amount);

  double totalForKind(ChargeKind kind) => _entries
      .where((e) => e.kind == kind)
      .fold<double>(0, (acc, e) => acc + e.amount);

  /// Totals for the last [months] calendar months, oldest first — the bars on
  /// the chart. Always returns exactly [months] buckets, empty ones included,
  /// so the chart keeps a stable shape.
  List<MonthTotal> monthlyTotals(int months) {
    final now = DateTime.now();
    final out = <MonthTotal>[];
    for (var i = months - 1; i >= 0; i--) {
      final m = DateTime(now.year, now.month - i, 1);
      out.add(MonthTotal(
        month: m,
        home:  _entries
            .where((e) => e.isHome &&
                e.date.year == m.year && e.date.month == m.month)
            .fold<double>(0, (s, e) => s + e.amount),
        paid: _entries
            .where((e) => !e.isHome &&
                e.date.year == m.year && e.date.month == m.month)
            .fold<double>(0, (s, e) => s + e.amount),
      ));
    }
    return out;
  }

  /// Wipes what this device holds, for the loaded scope and for [uid] when
  /// given. Used when the account itself is deleted — the screen may never have
  /// been opened this session, so the uid has to be passed in rather than read
  /// from the (by then signed-out) auth state.
  Future<void> clearLocal({String? uid}) async {
    final prefs = await SharedPreferences.getInstance();
    for (final scope in <String>{_scope, if (uid != null) uid}) {
      await prefs.remove('${_entriesKey}_$scope');
      await prefs.remove('${_deletesKey}_$scope');
    }
    _entries.clear();
    _pendingDeletes.clear();
    _bump();
  }
}

/// One bar on the monthly chart.
class MonthTotal {
  const MonthTotal({required this.month, required this.home, required this.paid});
  final DateTime month;
  final double home;
  final double paid;
  double get total => home + paid;
}

/// What one [ExpensesService.sync] should do. See [ExpensesService.planSync].
class ExpensesSyncPlan {
  const ExpensesSyncPlan({
    required this.upload,
    required this.adopt,
    required this.dropLocally,
  });

  /// Local entries to write to the server.
  final List<ExpenseEntry> upload;

  /// Server entries to write into the local list, new ones and newer ones.
  final List<ExpenseEntry> adopt;

  /// Ids of local entries deleted on another device.
  final List<String> dropLocally;
}
