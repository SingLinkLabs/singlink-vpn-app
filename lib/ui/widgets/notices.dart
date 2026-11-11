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
                              '顯示詳細資訊',
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
            tooltip: '關閉',
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
                  '找不到核心元件 libsinglink.dylib',
                  style: text.titleSmall?.copyWith(
                    color: cs.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '介面可以開啟，但無法新增伺服器或連線。請將核心放到以下路徑：',
                  style: text.bodySmall?.copyWith(color: cs.onErrorContainer),
                ),
                const SizedBox(height: 6),
                SelectableText(location.expectedPath, style: mono),
                if (location.searched.length > 1) ...[
                  const SizedBox(height: 8),
                  Text(
                    '或設定環境變數 SINGLINK_LIB，或於開發時放在 '
                    '../singlink-protocol/build/。已搜尋：',
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
                    '載入錯誤：',
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
