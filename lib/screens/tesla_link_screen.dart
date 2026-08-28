import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_strings.dart';
import '../services/shared_link_service.dart';
import 'google_route_import.dart';

/// Connecting the car at tesla.geocharge.ge to this account.
///
/// The car cannot ask for a password — most of these accounts were created with
/// Google and never had one — so it shows a 6-digit code instead and this
/// screen approves it. Approving is what proves the account: the phone is
/// already signed in as the subscriber. Server side: functions/tesla-pairing.js.
///
/// One account is linked to one car (`users/{uid}/flags/teslaDevice`). Pairing
/// a second one asks first, then takes the link away from the old car, which
/// signs itself out within seconds.
const _bgDark = Color(0xFF1A1A1A);
const _bgCard = Color(0xFF252525);
const _bgSurface = Color(0xFF2E2E2E);
const _emerald = Color(0xFF00C896);
const _textPri = Color(0xFFFFFFFF);
const _textSec = Color(0xFF9E9E9E);
const _errorRed = Color(0xFFCF6679);

class TeslaLinkScreen extends StatefulWidget {
  const TeslaLinkScreen({super.key});

  @override
  State<TeslaLinkScreen> createState() => _TeslaLinkScreenState();
}

class _TeslaLinkScreenState extends State<TeslaLinkScreen> {
  final _codeCtrl = TextEditingController();
  final _linkCtrl = TextEditingController();
  bool _busy = false;
  String _error = '';
  String _done = '';

  User? get _user => FirebaseAuth.instance.currentUser;

  @override
  void dispose() {
    _codeCtrl.dispose();
    _linkCtrl.dispose();
    super.dispose();
  }

  HttpsCallable _fn(String name) =>
      FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable(name);

  /// Approve the code shown in the car. [replace] is the second pass, after the
  /// user has agreed to drop whatever car is linked now.
  Future<void> _connect({bool replace = false}) async {
    final code = _codeCtrl.text.replaceAll(RegExp(r'\D'), '');
    if (code.length != 6) return;
    setState(() {
      _busy = true;
      _error = '';
      _done = '';
    });
    try {
      final res = await _fn('approveTeslaPairing')
          .call<Map<String, dynamic>>({'code': code, 'replace': replace});
      if (!mounted) return;

      if (res.data['needsReplace'] == true) {
        setState(() => _busy = false);
        if (await _confirmReplace()) await _connect(replace: true);
        return;
      }

      setState(() {
        _busy = false;
        _done = AppStrings.teslaDone;
        _codeCtrl.clear();
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = switch (e.code) {
          'not-found' || 'invalid-argument' => AppStrings.teslaBadCode,
          'resource-exhausted' => AppStrings.teslaTooMany,
          _ => AppStrings.teslaFailed,
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = AppStrings.teslaFailed;
      });
    }
  }

  Future<bool> _confirmReplace() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _bgCard,
        title: Text(AppStrings.teslaReplaceTitle,
            style: AppStrings.font(
                const TextStyle(color: _textPri, fontSize: 17))),
        content: Text(AppStrings.teslaReplaceBody,
            style: AppStrings.font(
                const TextStyle(color: _textSec, fontSize: 14, height: 1.5))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppStrings.cancel,
                style: AppStrings.font(const TextStyle(color: _textSec))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppStrings.teslaReplaceConfirm,
                style: AppStrings.font(const TextStyle(color: _emerald))),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _disconnect() async {
    setState(() {
      _busy = true;
      _error = '';
      _done = '';
    });
    try {
      await _fn('unlinkTeslaDevice').call<Map<String, dynamic>>();
    } catch (_) {
      if (mounted) setState(() => _error = AppStrings.teslaFailed);
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Read a pasted Google Maps link.
  ///
  /// This is how iOS gets the feature at all: appearing in Google Maps' share
  /// sheet there needs a Share Extension (its own target, App Group and
  /// provisioning profile), so until that exists the driver copies the link and
  /// pastes it here. Android has the share sheet and this as well, because a
  /// link that arrives by message rather than by share sheet still works.
  Future<void> _readPastedLink() async {
    final url = SharedLinkService.mapsLinkIn(_linkCtrl.text);
    if (url == null) {
      setState(() {
        _done = '';
        _error = AppStrings.teslaImportBadLink;
      });
      return;
    }
    setState(() {
      _error = '';
      _done = '';
    });
    await showGoogleRouteImport(context, url);
    if (mounted) _linkCtrl.clear();
  }

  Widget _importCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: _bgCard, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(AppStrings.teslaImportTitle,
            style: AppStrings.font(const TextStyle(
                color: _textPri, fontSize: 15, fontWeight: FontWeight.w600))),
        const SizedBox(height: 8),
        Text(AppStrings.teslaImportLead,
            style: AppStrings.font(const TextStyle(
                color: _textSec, fontSize: 13, height: 1.5))),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _linkCtrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              style: const TextStyle(color: _textPri, fontSize: 14),
              decoration: InputDecoration(
                hintText: AppStrings.teslaImportHint,
                hintStyle: const TextStyle(color: _textSec, fontSize: 14),
                filled: true,
                fillColor: _bgSurface,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _readPastedLink,
            child: Container(
              height: 50,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration: BoxDecoration(
                  color: _emerald, borderRadius: BorderRadius.circular(12)),
              child: Center(
                child: Text(AppStrings.teslaImportRead,
                    style: AppStrings.font(const TextStyle(
                        color: Colors.black,
                        fontSize: 14,
                        fontWeight: FontWeight.w700))),
              ),
            ),
          ),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = _user?.uid;
    return Scaffold(
      backgroundColor: _bgDark,
      appBar: AppBar(
        backgroundColor: _bgCard,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: _textPri, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(AppStrings.teslaTitle,
            style: const TextStyle(
                color: _textPri, fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: AppStrings.wrap(
        SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(AppStrings.teslaLead,
                  style: AppStrings.font(const TextStyle(
                      color: _textSec, fontSize: 14, height: 1.6))),
              const SizedBox(height: 24),

              if (uid == null)
                const SizedBox.shrink()
              else
                StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance
                      .doc('users/$uid/flags/teslaDevice')
                      .snapshots(),
                  builder: (_, snap) {
                    final linked = snap.data?.exists ?? false;
                    return linked
                        ? _connectedCard(snap.data!.data() ?? const {})
                        : _codeEntry();
                  },
                ),

              if (_error.isNotEmpty) ...[
                const SizedBox(height: 16),
                _banner(_error, _errorRed, Icons.error_outline_rounded),
              ],
              if (_done.isNotEmpty) ...[
                const SizedBox(height: 16),
                _banner(_done, _emerald, Icons.check_circle_outline_rounded),
              ],

              const SizedBox(height: 28),
              _importCard(),
              const SizedBox(height: 28),
              _steps(),
              const SizedBox(height: 20),
              Text(AppStrings.teslaOneCarNote,
                  style: AppStrings.font(const TextStyle(
                      color: _textSec, fontSize: 12, height: 1.5))),
            ],
          ),
        ),
      ),
    );
  }

  // ── Pieces ─────────────────────────────────────────────────────────────────

  Widget _codeEntry() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
          decoration: BoxDecoration(
            color: _bgCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _bgSurface),
          ),
          child: TextField(
            controller: _codeCtrl,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: 6,
            enabled: !_busy,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => setState(() {}), // enables the button at 6 digits
            style: const TextStyle(
              color: _textPri,
              fontSize: 30,
              fontWeight: FontWeight.w700,
              letterSpacing: 10,
            ),
            decoration: const InputDecoration(
              hintText: '000000',
              counterText: '',
              hintStyle: TextStyle(
                  color: _textSec, fontSize: 30, letterSpacing: 10),
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        const SizedBox(height: 14),
        _button(
          label: AppStrings.teslaConnect,
          icon: Icons.link_rounded,
          enabled: _codeCtrl.text.length == 6 && !_busy,
          onTap: _connect,
        ),
      ],
    );
  }

  Widget _connectedCard(Map<String, dynamic> data) {
    final ms = data['pairedAt'];
    final when = ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
    final stamp = when == null
        ? ''
        : '${when.day.toString().padLeft(2, '0')}.'
            '${when.month.toString().padLeft(2, '0')}.${when.year}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _emerald.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _emerald.withValues(alpha: 0.45)),
          ),
          child: Row(children: [
            const Icon(Icons.directions_car_filled_rounded,
                color: _emerald, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(AppStrings.teslaTileConnected,
                      style: AppStrings.font(const TextStyle(
                          color: _textPri,
                          fontSize: 15,
                          fontWeight: FontWeight.w600))),
                  if (stamp.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text('${AppStrings.teslaConnectedSince} $stamp',
                        style: AppStrings.font(const TextStyle(
                            color: _textSec, fontSize: 12))),
                  ],
                ],
              ),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        _button(
          label: AppStrings.teslaDisconnect,
          icon: Icons.link_off_rounded,
          enabled: !_busy,
          danger: true,
          onTap: _disconnect,
        ),
      ],
    );
  }

  Widget _steps() {
    final items = [
      AppStrings.teslaStep1,
      AppStrings.teslaStep2,
      AppStrings.teslaStep3,
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _bgSurface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                    color: _bgSurface, shape: BoxShape.circle),
                child: Text('${i + 1}',
                    style: const TextStyle(
                        color: _emerald,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(items[i],
                    style: AppStrings.font(const TextStyle(
                        color: _textSec, fontSize: 14, height: 1.45))),
              ),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _banner(String text, Color color, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(children: [
          Icon(icon, color: color, size: 17),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style:
                    AppStrings.font(TextStyle(color: color, fontSize: 13))),
          ),
        ]),
      );

  Widget _button({
    required String label,
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final accent = danger ? _errorRed : _emerald;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            color: danger ? _bgCard : accent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent),
          ),
          child: Center(
            child: _busy
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: danger ? accent : Colors.black),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon,
                          color: danger ? accent : Colors.black, size: 20),
                      const SizedBox(width: 8),
                      Text(label,
                          style: AppStrings.font(TextStyle(
                            color: danger ? accent : Colors.black,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ))),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
