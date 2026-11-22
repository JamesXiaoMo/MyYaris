import 'package:flutter/material.dart';

/// Shared visual tokens matching the redesigned MyYaris iOS app (YarisTheme).
abstract final class YarisCarTheme {
  static const canvas = Color(0xFFFAF9F4);
  static const paper = Color(0xFFFFFFFF);
  static const ink = Color(0xFF181B21);
  static const muted = Color(0xFF595F6C);
  static const blue = Color(0xFF3548E8);
  static const periwinkle = Color(0xFFE7EAFF);
  static const periwinkleDark = Color(0xFF243591);
  static const neutral = Color(0xFFEBE8DF);
  static const line = Color(0xFFE5E1D7);
  static const rose = Color(0xFFFBE0DF);
  static const red = Color(0xFFA82F36);
  static const green = Color(0xFF15803D);
  static const greenBg = Color(0xFFE7F7EC);
  static const amber = Color(0xFFB45309);
  static const amberBg = Color(0xFFFEF3C7);

  static final light = ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: canvas,
    colorScheme: const ColorScheme.light(
      primary: blue,
      onPrimary: Colors.white,
      primaryContainer: periwinkle,
      onPrimaryContainer: periwinkleDark,
      secondary: red,
      secondaryContainer: rose,
      onSecondaryContainer: red,
      surface: paper,
      onSurface: ink,
      onSurfaceVariant: muted,
      surfaceContainerHighest: neutral,
      outlineVariant: line,
    ),
    cardTheme: CardThemeData(
      color: paper,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: line, width: 1),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: neutral,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: ink,
      contentTextStyle: TextStyle(color: Colors.white, fontSize: 13),
    ),
  );

  static BoxDecoration cardDecoration({
    Color color = paper,
    double radius = 20,
    Color borderColor = line,
  }) {
    return BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: borderColor, width: 1),
    );
  }
}

/// Reusable album artwork with network cover image and geometric vinyl fallback.
class YarisMusicArtwork extends StatelessWidget {
  final double size;
  final double borderRadius;
  final String? badgeLabel;
  final String? coverUrl;

  const YarisMusicArtwork({
    super.key,
    this.size = 84,
    this.borderRadius = 18,
    this.badgeLabel,
    this.coverUrl,
  });

  String? get _normalizedCoverUrl {
    final raw = coverUrl?.trim();
    if (raw == null || raw.isEmpty) return null;
    if (raw.startsWith('http://') && raw.contains('music.126.net')) {
      return 'https://${raw.substring('http://'.length)}';
    }
    return raw;
  }

  Widget _buildFallback() {
    return Container(
      width: size,
      height: size,
      color: YarisCarTheme.blue,
      child: Stack(
        children: [
          Positioned(
            right: -size * 0.14,
            top: -size * 0.12,
            child: Container(
              width: size * 0.92,
              height: size * 0.92,
              decoration: const BoxDecoration(
                color: Color(0xFFFF6B6B),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            right: size * 0.02,
            top: size * 0.04,
            child: Container(
              width: size * 0.60,
              height: size * 0.60,
              decoration: const BoxDecoration(
                color: Color(0xFFFFB4A2),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            right: size * 0.14,
            top: size * 0.16,
            child: Container(
              width: size * 0.36,
              height: size * 0.36,
              decoration: const BoxDecoration(
                color: Color(0xFFFFE5D9),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            right: size * 0.24,
            top: size * 0.26,
            child: Container(
              width: size * 0.16,
              height: size * 0.16,
              decoration: const BoxDecoration(
                color: YarisCarTheme.blue,
                shape: BoxShape.circle,
              ),
            ),
          ),
          if (badgeLabel != null && badgeLabel!.isNotEmpty)
            Positioned(
              left: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  badgeLabel!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = _normalizedCoverUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: url != null
          ? SizedBox(
              width: size,
              height: size,
              child: Image.network(
                url,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _buildFallback(),
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : _buildFallback(),
              ),
            )
          : _buildFallback(),
    );
  }
}

/// Small status pill badge used consistently across all four tabs.
class YarisStatusPill extends StatelessWidget {
  final String text;
  final Color color;
  final Color backgroundColor;
  final bool showDot;

  const YarisStatusPill({
    super.key,
    required this.text,
    required this.color,
    required this.backgroundColor,
    this.showDot = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDot) ...[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
