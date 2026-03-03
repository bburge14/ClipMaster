import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/api_key_service.dart';

/// Onboarding wizard shown on first launch (when no API keys are configured).
///
/// Guides the user through setting up the API keys needed for each feature.
class OnboardingWizard extends ConsumerStatefulWidget {
  final VoidCallback onComplete;

  const OnboardingWizard({super.key, required this.onComplete});

  @override
  ConsumerState<OnboardingWizard> createState() => _OnboardingWizardState();
}

class _OnboardingWizardState extends ConsumerState<OnboardingWizard> {
  final _openaiController = TextEditingController();
  final _youtubeController = TextEditingController();
  final _pexelsController = TextEditingController();
  final _pixabayController = TextEditingController();
  final _claudeController = TextEditingController();
  final _geminiController = TextEditingController();
  final _githubController = TextEditingController();

  bool _saving = false;
  int _keysAdded = 0;

  @override
  void dispose() {
    _openaiController.dispose();
    _youtubeController.dispose();
    _pexelsController.dispose();
    _pixabayController.dispose();
    _claudeController.dispose();
    _geminiController.dispose();
    _githubController.dispose();
    super.dispose();
  }

  Future<void> _saveAndContinue() async {
    setState(() => _saving = true);
    final apiService = ref.read(apiKeyServiceProvider);
    int count = 0;

    final entries = [
      (LlmProvider.openai, _openaiController.text.trim()),
      (LlmProvider.youtube, _youtubeController.text.trim()),
      (LlmProvider.pexels, _pexelsController.text.trim()),
      (LlmProvider.pixabay, _pixabayController.text.trim()),
      (LlmProvider.claude, _claudeController.text.trim()),
      (LlmProvider.gemini, _geminiController.text.trim()),
      (LlmProvider.github, _githubController.text.trim()),
    ];

    for (final (provider, key) in entries) {
      if (key.isNotEmpty) {
        await apiService.addKey(provider, key);
        count++;
      }
    }

    setState(() {
      _saving = false;
      _keysAdded = count;
    });

    widget.onComplete();
  }

  void _openUrl(String url) {
    if (Platform.isWindows) {
      Process.run('start', [url], runInShell: true);
    } else if (Platform.isMacOS) {
      Process.run('open', [url]);
    } else {
      Process.run('xdg-open', [url]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141420),
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 680),
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            const Color(0xFF6C5CE7).withOpacity(0.3),
                            const Color(0xFF6C5CE7).withOpacity(0.1),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'CM',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF6C5CE7),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Welcome to ClipMaster Pro',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Set up your API keys to unlock all features.',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.white.withOpacity(0.4),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 32),

                // Feature overview
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C5CE7).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFF6C5CE7).withOpacity(0.2),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'How it works',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF6C5CE7),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'ClipMaster Pro uses a BYOK (Bring Your Own Key) model. '
                        'Your keys are encrypted and stored locally on your machine. '
                        'They are never sent to our servers — only to the API providers directly.',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withOpacity(0.5),
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // --- OpenAI (Primary) ---
                _buildApiKeySection(
                  icon: Icons.auto_awesome,
                  color: const Color(0xFF10A37F),
                  title: 'OpenAI API Key',
                  tag: 'Recommended',
                  description:
                      'Powers: AI Fact Generation, Text-to-Speech, Transcription (Whisper)',
                  instructions: [
                    '1. Go to platform.openai.com and sign up or log in',
                    '2. Navigate to API Keys in the left sidebar',
                    '3. Click "Create new secret key"',
                    '4. Copy the key (starts with sk-...)',
                  ],
                  linkText: 'Open OpenAI Platform',
                  linkUrl: 'https://platform.openai.com/api-keys',
                  controller: _openaiController,
                  hint: 'sk-...',
                ),
                const SizedBox(height: 16),

                // --- YouTube Data API ---
                _buildApiKeySection(
                  icon: Icons.play_circle_filled,
                  color: const Color(0xFFFF0000),
                  title: 'YouTube Data API Key',
                  tag: 'For Viral Scout',
                  description:
                      'Powers: Trending video discovery, YouTube search and analytics',
                  instructions: [
                    '1. Go to console.cloud.google.com',
                    '2. Create a project (or select existing)',
                    '3. Enable "YouTube Data API v3" in APIs & Services',
                    '4. Go to Credentials > Create Credentials > API Key',
                    '5. Copy the key (free tier: 10,000 units/day)',
                  ],
                  linkText: 'Open Google Cloud Console',
                  linkUrl: 'https://console.cloud.google.com/apis/library/youtube.googleapis.com',
                  controller: _youtubeController,
                  hint: 'AIza...',
                ),
                const SizedBox(height: 16),

                // --- Pexels ---
                _buildApiKeySection(
                  icon: Icons.movie_filter,
                  color: const Color(0xFF05A081),
                  title: 'Pexels API Key',
                  tag: 'For Stock Footage',
                  description:
                      'Powers: Free stock B-roll video search for your shorts',
                  instructions: [
                    '1. Go to pexels.com and create a free account',
                    '2. Go to pexels.com/api',
                    '3. Click "Your API Key" to generate one',
                    '4. Copy the key (completely free, no credit card)',
                  ],
                  linkText: 'Open Pexels API',
                  linkUrl: 'https://www.pexels.com/api/',
                  controller: _pexelsController,
                  hint: 'Pexels API key...',
                ),
                const SizedBox(height: 16),

                // --- Pixabay ---
                _buildApiKeySection(
                  icon: Icons.image,
                  color: const Color(0xFF48B648),
                  title: 'Pixabay API Key',
                  tag: 'For Stock Footage',
                  description:
                      'Powers: Additional free stock footage source (combined with Pexels)',
                  instructions: [
                    '1. Go to pixabay.com and create a free account',
                    '2. Go to pixabay.com/api/docs',
                    '3. Your API key is shown at the top of the docs page',
                    '4. Copy the key (completely free)',
                  ],
                  linkText: 'Open Pixabay API Docs',
                  linkUrl: 'https://pixabay.com/api/docs/',
                  controller: _pixabayController,
                  hint: 'Pixabay API key...',
                ),
                const SizedBox(height: 16),

                // --- Optional: Claude / Gemini ---
                _buildCollapsibleSection(
                  title: 'Alternative AI Providers (Optional)',
                  children: [
                    _buildApiKeySection(
                      icon: Icons.psychology,
                      color: const Color(0xFFD97706),
                      title: 'Claude API Key',
                      tag: 'Optional',
                      description: 'Alternative to OpenAI for fact generation',
                      instructions: [
                        '1. Go to console.anthropic.com',
                        '2. Create an account and add billing',
                        '3. Go to API Keys and create a key',
                      ],
                      linkText: 'Open Anthropic Console',
                      linkUrl: 'https://console.anthropic.com/settings/keys',
                      controller: _claudeController,
                      hint: 'sk-ant-...',
                    ),
                    const SizedBox(height: 12),
                    _buildApiKeySection(
                      icon: Icons.auto_fix_high,
                      color: const Color(0xFF4285F4),
                      title: 'Gemini API Key',
                      tag: 'Optional',
                      description: 'Alternative to OpenAI for fact generation',
                      instructions: [
                        '1. Go to aistudio.google.com/apikey',
                        '2. Click "Create API Key"',
                        '3. Copy the key (free tier available)',
                      ],
                      linkText: 'Open Google AI Studio',
                      linkUrl: 'https://aistudio.google.com/apikey',
                      controller: _geminiController,
                      hint: 'AIza...',
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // --- GitHub Token ---
                _buildCollapsibleSection(
                  title: 'Auto-Updater (Optional)',
                  children: [
                    _buildApiKeySection(
                      icon: Icons.system_update,
                      color: Colors.white70,
                      title: 'GitHub Personal Access Token',
                      tag: 'Optional',
                      description:
                          'For auto-updates from private GitHub releases',
                      instructions: [
                        '1. Go to github.com/settings/tokens',
                        '2. Generate new token (classic)',
                        '3. Select "repo" scope',
                        '4. Copy the token',
                      ],
                      linkText: 'Open GitHub Tokens',
                      linkUrl: 'https://github.com/settings/tokens',
                      controller: _githubController,
                      hint: 'ghp_...',
                    ),
                  ],
                ),

                const SizedBox(height: 32),

                // Action buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _saving ? null : widget.onComplete,
                      child: Text(
                        'Skip for now',
                        style: TextStyle(color: Colors.white.withOpacity(0.4)),
                      ),
                    ),
                    const SizedBox(width: 16),
                    FilledButton.icon(
                      onPressed: _saving ? null : _saveAndContinue,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.arrow_forward),
                      label: Text(_saving ? 'Saving...' : 'Get Started'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'You can always add or change keys later in Settings.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withOpacity(0.25),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildApiKeySection({
    required IconData icon,
    required Color color,
    required String title,
    required String tag,
    required String description,
    required List<String> instructions,
    required String linkText,
    required String linkUrl,
    required TextEditingController controller,
    required String hint,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  tag,
                  style: TextStyle(fontSize: 10, color: color),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withOpacity(0.4),
            ),
          ),
          const SizedBox(height: 10),
          // Instructions
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.03),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'How to get this key:',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withOpacity(0.5),
                  ),
                ),
                const SizedBox(height: 6),
                ...instructions.map(
                  (step) => Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      step,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.35),
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                InkWell(
                  onTap: () => _openUrl(linkUrl),
                  child: Text(
                    linkText,
                    style: TextStyle(
                      fontSize: 12,
                      color: color,
                      decoration: TextDecoration.underline,
                      decorationColor: color,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // Key input
          SizedBox(
            height: 40,
            child: TextField(
              controller: controller,
              obscureText: true,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: hint,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCollapsibleSection({
    required String title,
    required List<Widget> children,
  }) {
    return ExpansionTile(
      title: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: Colors.white.withOpacity(0.5),
        ),
      ),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      iconColor: Colors.white38,
      collapsedIconColor: Colors.white24,
      children: children,
    );
  }
}
