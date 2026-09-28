import 'package:flutter/material.dart';

/// Short, state-driven motion that also respects the system animation setting.
class AppMotion {
  static Duration short(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations == true
      ? Duration.zero
      : const Duration(milliseconds: 180);

  static Duration medium(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations == true
      ? Duration.zero
      : const Duration(milliseconds: 240);

  static Widget topStart(Widget? currentChild, List<Widget> previousChildren) =>
      Stack(
        alignment: AlignmentDirectional.topStart,
        children: [...previousChildren, ?currentChild],
      );
}
