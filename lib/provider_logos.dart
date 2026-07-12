import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

// ── Provider logos ────────────────────────────────────────────────────────────
// Maps a station's `provider` string to its bundled logo asset. Mirrors the
// Tesla web build's providerLogo() mapping (tesla/js/format.js) so both clients
// stay in sync. Providers with no logo (e.g. OCM "International") return null.
const Map<String, String> _providerLogoFiles = {
  'e-space':           'espace.svg',
  'mart ev':           'martev.svg',
  'moveo':             'moveo.png',
  'electrify georgia': 'electrify.png',
  'ev power ge':       'evpower.png',
  'da-tene':           'datene.png',
  'gadatene':          'gadatene-dark.svg',
  'ecocars':           'ecocars.png',
  'solar station':     'solarstation.png',
  'tegeta':            'tegeta.png',
  'charger plus':      'chargerplus.png',
  'socar':             'socar.png',
};

/// Asset path for a provider's logo, or null when none is bundled.
String? providerLogoAsset(String provider) {
  final file = _providerLogoFiles[provider.trim().toLowerCase()];
  return file == null ? null : 'assets/providers/$file';
}

/// Small logo chip for a provider. The logos are drawn for light backgrounds
/// (like the marketing site's white cards), so we sit each one on a rounded
/// white tile to keep it legible on the app's dark surfaces. Renders nothing
/// when the provider has no bundled logo.
class ProviderLogo extends StatelessWidget {
  const ProviderLogo({super.key, required this.provider, this.height = 26});

  final String provider;
  final double height;

  @override
  Widget build(BuildContext context) {
    final asset = providerLogoAsset(provider);
    if (asset == null) { return const SizedBox.shrink(); }

    final Widget img = asset.endsWith('.svg')
        ? SvgPicture.asset(asset, height: height - 8, fit: BoxFit.contain)
        : Image.asset(asset, height: height - 8, fit: BoxFit.contain);

    return Container(
      height: height,
      constraints: BoxConstraints(minWidth: height, maxWidth: height * 2.4),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: img,
    );
  }
}
