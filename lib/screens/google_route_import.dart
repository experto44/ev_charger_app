import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../services/tesla_route_service.dart';

/// A route shared out of Google Maps, on its way to the car.
///
/// Opened either by the Android share sheet (MainActivity.kt →
/// SharedLinkService) or by pasting a link on the Tesla screen. The link is
/// read by a Cloud Function, the driver sees what came back, and only then is
/// anything sent — a share sheet tap is not consent to put a route in the car.
const _bgCard = Color(0xFF252525);
const _bgSurface = Color(0xFF2E2E2E);
const _emerald = Color(0xFF00C896);
const _textPri = Color(0xFFFFFFFF);
const _textSec = Color(0xFF9E9E9E);
const _errorRed = Color(0xFFCF6679);

/// Read [url] and offer to send it to the car.
///
/// A route has nowhere to go while signed out, but it must not disappear in
/// silence either: someone who shared a link and saw nothing happen would
/// reasonably conclude the feature is broken.
Future<void> showGoogleRouteImport(BuildContext context, String url) async {
  if (FirebaseAuth.instance.currentUser == null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: _bgCard,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      content: Text(AppStrings.teslaSendSignedOut,
          style: const TextStyle(color: _textPri)),
    ));
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _ImportSheet(url: url),
  );
}

class _ImportSheet extends StatefulWidget {
  const _ImportSheet({required this.url});
  final String url;

  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  TeslaRoute? _route;
  String _error = '';
  bool _busy = true;
  bool _sent = false;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final r = await TeslaRouteService.readGoogleLink(widget.url);
      if (!mounted) return;
      setState(() {
        _route = r;
        _busy = false;
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // `details.reason` rather than the message text: the server's prose is
        // not an API and gets reworded.
        final reason = (e.details is Map) ? e.details['reason'] : null;
        _error = switch (e.code) {
          'invalid-argument' when reason == 'not-driving' =>
            AppStrings.teslaImportNotDriving,
          'invalid-argument' => AppStrings.teslaImportBadLink,
          'resource-exhausted' => AppStrings.teslaImportTooMany,
          _ => AppStrings.teslaImportUnreadable,
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = AppStrings.teslaImportUnreadable;
      });
    }
  }

  Future<void> _send() async {
    final r = _route;
    if (r == null) return;
    setState(() => _busy = true);
    try {
      final linked = await TeslaRouteService.isCarLinked();
      await TeslaRouteService.sendToCar(r, source: 'gmaps');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _sent = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: _bgCard,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Text(
          linked ? AppStrings.teslaSentOk : AppStrings.teslaSentNoCar,
          style: const TextStyle(color: _textPri),
        ),
      ));
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = AppStrings.teslaSendFailed;
      });
    }
  }

  /// "2 stops · no toll roads", or "Direct".
  String _summary(TeslaRoute r) {
    final bits = <String>[
      r.waypoints.isEmpty
          ? AppStrings.teslaImportDirect
          : AppStrings.teslaImportStops(r.waypoints.length),
      if (r.avoidTolls) AppStrings.teslaImportNoTolls,
    ];
    return bits.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final r = _route;
    return Container(
      padding: EdgeInsets.fromLTRB(
          20, 18, 20, 24 + MediaQuery.of(context).viewInsets.bottom),
      decoration: const BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
              color: _bgSurface, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 18),
        Text(AppStrings.teslaImportTitle,
            style: AppStrings.font(const TextStyle(
                color: _textPri, fontSize: 17, fontWeight: FontWeight.w600))),
        const SizedBox(height: 16),

        if (_busy && r == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: CircularProgressIndicator(strokeWidth: 2, color: _emerald),
          )
        else if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_error,
                textAlign: TextAlign.center,
                style: AppStrings.font(const TextStyle(
                    color: _errorRed, fontSize: 14, height: 1.4))),
          )
        else if (r != null) ...[
          Text(r.name,
              textAlign: TextAlign.center,
              style: AppStrings.font(const TextStyle(
                  color: _textPri, fontSize: 20, fontWeight: FontWeight.w600))),
          const SizedBox(height: 6),
          Text(_summary(r),
              style: AppStrings.font(
                  const TextStyle(color: _emerald, fontSize: 14))),
          if (r.droppedStops.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(AppStrings.teslaImportDropped,
                textAlign: TextAlign.center,
                style: AppStrings.font(
                    const TextStyle(color: _textSec, fontSize: 13, height: 1.4))),
          ],
        ],

        const SizedBox(height: 22),
        Row(children: [
          Expanded(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(AppStrings.cancel,
                  style: AppStrings.font(const TextStyle(color: _textSec))),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: GestureDetector(
              // After a failure the same button retries the read: the link is
              // usually fine and the network was not.
              onTap: _busy || _sent
                  ? null
                  : (_error.isNotEmpty ? _read : (r == null ? null : _send)),
              child: Container(
                height: 50,
                decoration: BoxDecoration(
                  color: (r == null && _error.isEmpty) || _busy ? _bgSurface : _emerald,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Center(
                  child: _busy && r != null
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black))
                      : Text(
                          _error.isNotEmpty
                              ? AppStrings.teslaImportRead
                              : AppStrings.teslaSendToCar,
                          style: AppStrings.font(TextStyle(
                            color: (r == null && _error.isEmpty)
                                ? _textSec
                                : Colors.black,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          )),
                        ),
                ),
              ),
            ),
          ),
        ]),
      ]),
    );
  }
}
