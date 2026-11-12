// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';

import '../../core/error_messages.dart';
import '../../core/singlink_bindings.dart';

/// Friendly connection error with optional technical detail for support.
class ErrorNotice extends StatefulWidget {
  const ErrorNotice({super.key, required this.error, required this.onClose});
  final FriendlyError error;
  final VoidCallback onClose;

  @override
  State<ErrorNotice> createState() => _ErrorNoticeState();
}

class _ErrorNoticeState extends State<ErrorNotice> {
  bool _detail = false;

  @override
  void didUpdateWidget(ErrorNotice old) {
    super.didUpdateWidget(old);
    if (old.error != widget.error) _detail = false;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final fg = cs.onErrorContainer;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.error_outline_rounded, color: fg, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.error.message,
                  style: text.bodyMedium?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (widget.error.detail.isNotEmpty)
                  _detail
                      ? Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: SelectableText(
                            widget.error.detail,
                            style: text.bodySmall?.copyWith(color: fg),
                          ),
                        )
                      : GestureDetector(
                          onTap: () => setState(() => _detail = true),
                          child: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              'Show details',
                              style: text.labelSmall?.copyWith(
                                color: fg,
                                decoration: TextDecoration.underline,
                                decorationColor: fg,
                              ),
                            ),
                          ),
                        ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Close',
            icon: Icon(Icons.close_rounded, color: fg, size: 18),
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }
}

/// Amber warning (e.g. system proxy could not be set). Still connected.
class WarningNotice extends StatelessWidget {
  const WarningNotice({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF3A2E12) : const Color(0xFFFFF4D6);
    final fg = dark ? const Color(0xFFFFD98A) : const Color(0xFF7A5200);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: fg, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: fg, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown instead of crashing when libsinglink cannot be loaded.
class CoreMissingBanner extends StatelessWidget {
  const CoreMissingBanner({super.key, required this.location});

  final SingLinkLibLocation location;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final mono = text.bodySmall?.copyWith(
      fontFamily: 'Menlo',
      color: cs.onErrorContainer,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.extension_off_rounded, color: cs.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Core library libsinglink.dylib not found',
                  style: text.titleSmall?.copyWith(
                    color: cs.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "The app opens, but you can't add servers or connect. Put the core library here:",
                  style: text.bodySmall?.copyWith(color: cs.onErrorContainer),
                ),
                const SizedBox(height: 6),
                SelectableText(location.expectedPath, style: mono),
                if (location.searched.length > 1) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Or set the SINGLINK_LIB environment variable, or during development '
                    'put it in ../singlink-protocol/build/. Searched:',
                    style: text.bodySmall?.copyWith(color: cs.onErrorContainer),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    location.searched.skip(1).join('\n'),
                    style: mono,
                  ),
                ],
                if (location.errors.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Load errors:',
                    style: text.bodySmall?.copyWith(color: cs.onErrorContainer),
                  ),
                  SelectableText(location.errors.join('\n'), style: mono),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
