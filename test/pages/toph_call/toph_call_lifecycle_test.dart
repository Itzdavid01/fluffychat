// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/pages/toph_call/toph_call_page.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isHaltingLifecycleState', () {
    test('returns true for AppLifecycleState.paused', () {
      expect(isHaltingLifecycleState(AppLifecycleState.paused), isTrue);
    });

    test('returns true for AppLifecycleState.inactive', () {
      expect(isHaltingLifecycleState(AppLifecycleState.inactive), isTrue);
    });

    test('returns true for AppLifecycleState.detached', () {
      expect(isHaltingLifecycleState(AppLifecycleState.detached), isTrue);
    });

    test('returns false for AppLifecycleState.resumed', () {
      expect(isHaltingLifecycleState(AppLifecycleState.resumed), isFalse);
    });

    test('returns false for AppLifecycleState.hidden', () {
      expect(isHaltingLifecycleState(AppLifecycleState.hidden), isFalse);
    });

    test('halting states never overlap with non-halting states', () {
      final halting = AppLifecycleState.values
          .where(isHaltingLifecycleState)
          .toSet();
      final nonHalting = AppLifecycleState.values
          .where((s) => !isHaltingLifecycleState(s))
          .toSet();

      expect(halting.intersection(nonHalting), isEmpty);
    });

    test('every AppLifecycleState value is classified (exhaustive coverage)',
        () {
      // If a new state is added to the SDK enum and the switch is not updated,
      // the switch in isHaltingLifecycleState will fail to compile.  This test
      // verifies that all currently known values are handled without throwing.
      for (final state in AppLifecycleState.values) {
        expect(() => isHaltingLifecycleState(state), returnsNormally);
      }
    });

    test('exactly paused, inactive, detached are halting', () {
      const expectedHalting = {
        AppLifecycleState.paused,
        AppLifecycleState.inactive,
        AppLifecycleState.detached,
      };
      final actualHalting =
          AppLifecycleState.values.where(isHaltingLifecycleState).toSet();
      expect(actualHalting, equals(expectedHalting));
    });
  });
}
