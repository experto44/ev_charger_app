import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const EVChargerApp());
}

// ── Theme constants ──────────────────────────────────────────────────────────
const _bgDark = Color(0xFF1A1A1A);
const _bgCard = Color(0xFF252525);
const _bgSurface = Color(0xFF2E2E2E);
const _emerald = Color(0xFF00C896);
const _textPrimary = Color(0xFFFFFFFF);
const _textSecondary = Color(0xFF9E9E9E);

// ── Station data with real Tbilisi coordinates ────────────────────────────────
class _Station {
  const _Station(
      this.name, this.location, this.distance, this.available, this.lat, this.lng);
  final String name, location, distance;
  final int available;
  final double lat, lng;
}

const _stations = [
  _Station('Tegeta Motors', 'Vake',      '1.2 km', 4, 41.6925, 44.7734),
  _Station('E-Space',       'Saburtalo', '2.5 km', 2, 41.7234, 44.7658),
  _Station('Autopark',      'Didube',    '3.1 km', 6, 41.7393, 44.7855),
  _Station('GreenCharge',   'Isani',     '4.8 km', 1, 41.6852, 44.8301),
  _Station('City Hub',      'Gldani',    '5.4 km', 3, 41.7797, 44.7935),
];

Future<void> _navigate(double lat, double lng) async {
  final uri = Uri.parse('https://www.google.com/maps/@$lat,$lng,15z');
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

// ── App root ─────────────────────────────────────────────────────────────────
class EVChargerApp extends StatelessWidget {
  const EVChargerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EV Charger Georgia',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: _bgDark,
        colorScheme: const ColorScheme.dark(
          primary: _emerald,
          surface: _bgCard,
        ),
      ),
      home: const MapScreen(),
    );
  }
}

// ── Main screen ───────────────────────────────────────────────────────────────
class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  static const _tbilisi = LatLng(41.7151, 44.8271);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            options: const MapOptions(
              initialCenter: _tbilisi,
              initialZoom: 13,
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
                subdomains: const ['a', 'b', 'c', 'd'],
                userAgentPackageName: 'com.example.ev_charger_app',
                retinaMode: MediaQuery.devicePixelRatioOf(context) >= 2,
              ),
            ],
          ),
          const SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _SearchBar(),
            ),
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _StationCarousel(),
          ),
        ],
      ),
    );
  }
}

// ── Search bar ────────────────────────────────────────────────────────────────
class _SearchBar extends StatelessWidget {
  const _SearchBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 54,
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Colors.black38, blurRadius: 12, offset: Offset(0, 4))
        ],
      ),
      child: const Row(
        children: [
          SizedBox(width: 14),
          Icon(Icons.search, color: _textSecondary, size: 22),
          SizedBox(width: 10),
          Expanded(
            child: TextField(
              style: TextStyle(color: _textPrimary, fontSize: 15),
              decoration: InputDecoration(
                hintText: 'Search charging stations…',
                hintStyle: TextStyle(color: _textSecondary, fontSize: 15),
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
          _IconBtn(icon: Icons.tune),
          SizedBox(width: 4),
          _IconBtn(icon: Icons.account_circle_outlined),
          SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: _bgSurface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: _textSecondary, size: 20),
    );
  }
}

// ── Station carousel ──────────────────────────────────────────────────────────
class _StationCarousel extends StatelessWidget {
  const _StationCarousel();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [_bgDark, Colors.transparent],
          stops: [0.6, 1.0],
        ),
      ),
      padding: const EdgeInsets.only(top: 32, bottom: 24),
      child: SizedBox(
        height: 168,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: _stations.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (_, i) => _StationCard(_stations[i]),
        ),
      ),
    );
  }
}

// ── Station card ──────────────────────────────────────────────────────────────
class _StationCard extends StatelessWidget {
  const _StationCard(this.s);
  final _Station s;

  @override
  Widget build(BuildContext context) {
    final isLow = s.available <= 1;
    final statusColor = isLow ? Colors.orangeAccent : _emerald;

    return Container(
      width: 170,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 4))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status indicator
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                '${s.available} available',
                style: TextStyle(
                    color: statusColor, fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Name + neighbourhood
          Text(
            s.name,
            style: const TextStyle(
                color: _textPrimary, fontSize: 14, fontWeight: FontWeight.bold),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(s.location,
              style: const TextStyle(color: _textSecondary, fontSize: 12)),
          const Spacer(),
          // Distance row
          Row(
            children: [
              const Icon(Icons.near_me_outlined, color: _textSecondary, size: 13),
              const SizedBox(width: 4),
              Text(s.distance,
                  style: const TextStyle(color: _textSecondary, fontSize: 12)),
              const Spacer(),
              const Icon(Icons.bolt, color: _emerald, size: 16),
            ],
          ),
          const SizedBox(height: 10),
          // Navigate button
          GestureDetector(
            onTap: () => _navigate(s.lat, s.lng),
            child: Container(
              height: 32,
              decoration: BoxDecoration(
                color: _emerald,
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.navigation_rounded, color: Colors.black, size: 14),
                  SizedBox(width: 5),
                  Text(
                    'Navigate',
                    style: TextStyle(
                        color: Colors.black,
                        fontSize: 12,
                        fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
