import 'package:flutter/material.dart';

import '../../core/client_controller.dart';
import '../format.dart';
import '../theme.dart';

/// Live download / upload speed and the session's total usage.
class SpeedCards extends StatelessWidget {
  const SpeedCards({super.key, required this.c});
  final ClientController c;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final live = c.isConnected;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _SpeedCard(
                label: '下載',
                icon: Icons.arrow_downward_rounded,
                color: Brand.primary,
                rate: live ? c.downRate : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _SpeedCard(
                label: '上傳',
                icon: Icons.arrow_upward_rounded,
                color: Brand.accent,
                rate: live ? c.upRate : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          live ? '本次用量 ${formatBytes(c.totalBytes)}' : '本次用量 —',
          style: text.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _SpeedCard extends StatelessWidget {
  const _SpeedCard({
    required this.label,
    required this.icon,
    required this.color,
    required this.rate,
  });

  final String label;
  final IconData icon;
  final Color color;

  /// Null while disconnected.
  final double? rate;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final (value, unit) = rate == null ? ('—', '') : formatRateParts(rate!);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: text.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: value,
                          style: text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (unit.isNotEmpty)
                          TextSpan(
                            text: ' $unit',
                            style: text.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
