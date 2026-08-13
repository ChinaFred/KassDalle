import 'package:flutter/material.dart';

class CooklangToolbarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color bgColor;
  final Color iconColor;
  final VoidCallback onTap;

  const CooklangToolbarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.bgColor,
    required this.iconColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 17, color: iconColor),
          ),
        ),
      ),
    );
  }
}

class CooklangToolbarDivider extends StatelessWidget {
  const CooklangToolbarDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: VerticalDivider(
        indent: 6,
        endIndent: 6,
        width: 12,
        color: Theme.of(context).dividerColor,
      ),
    );
  }
}
