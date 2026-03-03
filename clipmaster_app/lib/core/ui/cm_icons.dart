import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Custom monochromatic icon set for ClipMaster Pro.
///
/// All icons share a flat, geometric, slightly futuristic white vector style.
/// Use [CmIcon] widget to render them at any size/color.
///
/// Navigation icons:
///   - scout: Magnifying glass with a play button inside the lens
///   - ingest: Anchor symbol with a download arrow
///   - edit: Three horizontal timeline bars with a diamond keyframe
///   - publish: Vertical rectangle with an upload arrow
///   - license: Geometric key with a subtle 'N'
///
/// Platform logos:
///   - twitch: The Glitch square logo
///   - tiktok: The Music Note 'd' logo
///   - youtube: The classic Play Button triangle in a square
///   - claude: The abstract Anthropic 'A' mask
///   - chatgpt: The OpenAI spiral dot
///   - gemini: The Google 'G' mask with a star sparkle
enum CmIconId {
  // Navigation
  scout,
  ingest,
  edit,
  publish,
  license,

  // Platforms
  twitch,
  tiktok,
  youtube,
  claude,
  chatgpt,
  gemini,
}

/// Maps each icon ID to its asset path.
const _iconAssets = <CmIconId, String>{
  CmIconId.scout: 'assets/icons/scout.svg',
  CmIconId.ingest: 'assets/icons/ingest.svg',
  CmIconId.edit: 'assets/icons/edit.svg',
  CmIconId.publish: 'assets/icons/publish.svg',
  CmIconId.license: 'assets/icons/license.svg',
  CmIconId.twitch: 'assets/icons/platform_twitch.svg',
  CmIconId.tiktok: 'assets/icons/platform_tiktok.svg',
  CmIconId.youtube: 'assets/icons/platform_youtube.svg',
  CmIconId.claude: 'assets/icons/platform_claude.svg',
  CmIconId.chatgpt: 'assets/icons/platform_chatgpt.svg',
  CmIconId.gemini: 'assets/icons/platform_gemini.svg',
};

/// Widget that renders a ClipMaster custom icon from SVG assets.
///
/// Usage:
/// ```dart
/// CmIcon(CmIconId.scout, size: 24)
/// CmIcon(CmIconId.youtube, size: 20, color: Colors.red)
/// ```
class CmIcon extends StatelessWidget {
  final CmIconId icon;
  final double size;
  final Color? color;

  const CmIcon(this.icon, {super.key, this.size = 24, this.color});

  @override
  Widget build(BuildContext context) {
    final assetPath = _iconAssets[icon]!;
    final effectiveColor = color ?? Colors.white;

    return SvgPicture.asset(
      assetPath,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(effectiveColor, BlendMode.srcIn),
    );
  }
}

/// Convenience: returns a platform [CmIconId] from a platform string.
CmIconId? platformToIcon(String platform) {
  return switch (platform.toLowerCase()) {
    'youtube' => CmIconId.youtube,
    'twitch' => CmIconId.twitch,
    'tiktok' => CmIconId.tiktok,
    _ => null,
  };
}
