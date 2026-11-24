import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_choice.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/models/session_spec.dart';
import 'package:extendedscreen/shared/services/app_translations.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const extended = SessionMode.extendedScreen;
  const remote = SessionMode.remoteControl;
  const tabDrives = RemoteDirection.tabControlsMac;
  const macDrives = RemoteDirection.macControlsTab;

  group('SessionChoice', () {
    test('the direction defaults to the tablet driving the Mac', () {
      expect(const SessionChoice(extended).direction, tabDrives);
      expect(const SessionChoice(remote).direction, tabDrives);
    });

    test('equal choices are equal, and hash alike', () {
      expect(const SessionChoice(remote, macDrives),
          SessionChoice(SessionMode.values[1], RemoteDirection.values[1]));
      expect(const SessionChoice(remote, macDrives).hashCode,
          SessionChoice(SessionMode.values[1], RemoteDirection.values[1]).hashCode);
      expect(const SessionChoice(remote, macDrives),
          isNot(const SessionChoice(remote, tabDrives)));
      expect(const SessionChoice(extended, macDrives),
          isNot(const SessionChoice(remote, macDrives)));
      // Equality is of the choice as picked: an Extended screen's unused
      // direction still tells two apart (sameEffect is what ignores it).
      expect(const SessionChoice(extended, macDrives),
          isNot(const SessionChoice(extended, tabDrives)));
    });

    test('all lists Extended, then both remote directions', () {
      expect(SessionChoice.all, const [
        SessionChoice(extended),
        SessionChoice(remote, tabDrives),
        SessionChoice(remote, macDrives),
      ]);
    });

    test('over Wi-Fi the tablet drives the Mac, in every mode', () {
      for (final mode in SessionMode.values) {
        for (final direction in RemoteDirection.values) {
          final e = SessionChoice(mode, direction)
              .effective(link: LinkType.wifi);
          expect(e.mode, mode);
          expect(e.direction, tabDrives, reason: '$mode $direction');
        }
      }
    });

    test('a device that is not Android drives the Mac, on either link', () {
      for (final link in LinkType.values) {
        for (final mode in SessionMode.values) {
          for (final direction in RemoteDirection.values) {
            final e = SessionChoice(mode, direction)
                .effective(link: link, android: false);
            expect(e.mode, mode);
            expect(e.direction, tabDrives, reason: '$link $mode $direction');
          }
        }
      }
    });

    test('over USB an Android tablet keeps the choice as given', () {
      for (final choice in const [
        SessionChoice(extended, tabDrives),
        // An Extended screen carries the saved direction untouched.
        SessionChoice(extended, macDrives),
        SessionChoice(remote, tabDrives),
        SessionChoice(remote, macDrives),
      ]) {
        expect(choice.effective(link: LinkType.usb), choice);
        expect(choice.effective(link: LinkType.usb, android: true), choice);
      }
    });

    test('only remote control with the Mac driving is reverse', () {
      expect(const SessionChoice(remote, macDrives).isReverse, isTrue);
      expect(const SessionChoice(remote, tabDrives).isReverse, isFalse);
      expect(const SessionChoice(extended, macDrives).isReverse, isFalse);
      expect(const SessionChoice(extended, tabDrives).isReverse, isFalse);
      for (final mode in SessionMode.values) {
        for (final direction in RemoteDirection.values) {
          final c = SessionChoice(mode, direction);
          expect(c.encodesOnMac, !c.isReverse);
        }
      }
      // What the link makes of it decides, not the pick.
      expect(
          const SessionChoice(remote, macDrives)
              .effective(link: LinkType.wifi)
              .isReverse,
          isFalse);
    });

    test('sameEffect ignores the direction of an Extended screen only', () {
      expect(
          const SessionChoice(extended, tabDrives)
              .sameEffect(const SessionChoice(extended, macDrives)),
          isTrue);
      expect(
          const SessionChoice(remote, tabDrives)
              .sameEffect(const SessionChoice(remote, macDrives)),
          isFalse);
      expect(
          const SessionChoice(remote, macDrives)
              .sameEffect(const SessionChoice(remote, macDrives)),
          isTrue);
      expect(
          const SessionChoice(extended, macDrives)
              .sameEffect(const SessionChoice(remote, macDrives)),
          isFalse);
      expect(
          const SessionChoice(remote, tabDrives)
              .sameEffect(const SessionChoice(extended, tabDrives)),
          isFalse);
      // Over Wi-Fi both remote directions come to the same thing.
      expect(
          const SessionChoice(remote, tabDrives)
              .effective(link: LinkType.wifi)
              .sameEffect(const SessionChoice(remote, macDrives)
                  .effective(link: LinkType.wifi)),
          isTrue);
    });

    test('label names the mode, and the direction for remote control', () {
      final keys = AppTranslations().keys;
      Get.addTranslations(keys);
      addTearDown(() {
        Get.clearTranslations();
        Get.locale = null;
      });
      for (final code in ['en', 'th']) {
        Get.locale = Locale(code);
        final t = keys[code]!;
        expect(const SessionChoice(extended).label,
            t['session_extended_label']);
        expect(const SessionChoice(extended, macDrives).label,
            t['session_extended_label']);
        expect(const SessionChoice(remote, tabDrives).label,
            '${t['session_remote_label']} · ${t['remote_dir_tab_label']}');
        expect(const SessionChoice(remote, macDrives).label,
            '${t['session_remote_label']} · ${t['remote_dir_mac_label']}');
      }
      // The two languages really differ, so the loop proved a switch.
      expect(keys['en']!['session_remote_label'],
          isNot(keys['th']!['session_remote_label']));
    });

    test('roleLabel and roleDescription name the three roles in plain '
        'words, the Mac driving only for remote control with the Mac '
        'driving', () {
      final keys = AppTranslations().keys;
      Get.addTranslations(keys);
      addTearDown(() {
        Get.clearTranslations();
        Get.locale = null;
      });
      for (final code in ['en', 'th']) {
        Get.locale = Locale(code);
        final t = keys[code]!;
        for (final c in [
          const SessionChoice(extended),
          const SessionChoice(extended, macDrives),
        ]) {
          expect(c.roleLabel, t['role_extended']);
          expect(c.roleDescription, t['role_extended_desc']);
        }
        expect(const SessionChoice(remote, tabDrives).roleLabel,
            t['role_controls_mac']);
        expect(const SessionChoice(remote, tabDrives).roleDescription,
            t['role_controls_mac_desc']);
        expect(const SessionChoice(remote, macDrives).roleLabel,
            t['role_mac_controls']);
        expect(
            const SessionChoice(remote, macDrives).roleDescription,
            t['role_mac_controls_desc']!
                .replaceAll('@share', t['home_start_share']!));
        expect(const SessionChoice(remote, macDrives).roleDescription,
            isNot(contains('@')));
      }
      expect(keys['en']!['role_mac_controls'],
          'The Mac controls this device');
      expect(keys['th']!['role_mac_controls'], isNot(keys['en']!['role_mac_controls']));
    });

    test('fromNames reads enum names and survives unknown ones', () {
      expect(SessionChoice.fromNames('extendedScreen', 'tabControlsMac'),
          const SessionChoice(extended, tabDrives));
      expect(SessionChoice.fromNames('extendedScreen', 'macControlsTab'),
          const SessionChoice(extended, macDrives));
      expect(SessionChoice.fromNames('remoteControl', 'macControlsTab'),
          const SessionChoice(remote, macDrives));
      // Every choice goes through its names and back.
      for (final mode in SessionMode.values) {
        for (final direction in RemoteDirection.values) {
          expect(SessionChoice.fromNames(mode.name, direction.name),
              SessionChoice(mode, direction));
        }
      }
      // An unknown mode is no choice, whatever the direction says.
      expect(SessionChoice.fromNames('bogus', 'macControlsTab'), isNull);
      expect(SessionChoice.fromNames(null, null), isNull);
      expect(SessionChoice.fromNames(null, 'macControlsTab'), isNull);
      expect(SessionChoice.fromNames(1, 'macControlsTab'), isNull);
      expect(SessionChoice.fromNames('', ''), isNull);
      // An unknown or missing direction is the default one.
      expect(SessionChoice.fromNames('remoteControl', 'bogus'),
          const SessionChoice(remote, tabDrives));
      expect(SessionChoice.fromNames('remoteControl', null),
          const SessionChoice(remote, tabDrives));
      expect(SessionChoice.fromNames('remoteControl', 7),
          const SessionChoice(remote, tabDrives));
    });
  });

  group('SessionSpec.from', () {
    void expectSpec(SessionSpec got, SessionSpec want, String reason) {
      expect(got.link, want.link, reason: reason);
      expect(got.mode, want.mode, reason: reason);
      expect(got.direction, want.direction, reason: reason);
      expect(got.displayMode, want.displayMode, reason: reason);
      expect(got.isReverseRemote, want.isReverseRemote, reason: reason);
    }

    test(
        'SessionSpec.of is SessionSpec.from(nextChoice) for every mode, '
        'direction, link and display mode', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      await settings.init();
      for (final mode in SessionMode.values) {
        for (final direction in RemoteDirection.values) {
          for (final displayMode in DisplayMode.values) {
            await settings.setSessionMode(mode);
            await settings.setRemoteDirection(direction);
            await settings.setDisplayMode(displayMode);
            expect(settings.nextChoice, SessionChoice(mode, direction));
            for (final link in LinkType.values) {
              final reason = '$mode $direction $displayMode $link';
              final of = SessionSpec.of(settings, link);
              expectSpec(
                  of,
                  SessionSpec.from(settings.nextChoice, link,
                      displayMode: settings.displayMode),
                  reason);
              // What SessionSpec.of worked out before there were choices,
              // written out, and what the settings' own getters say when
              // the link is the saved one.
              expectSpec(
                  of,
                  SessionSpec(
                    link: link,
                    mode: mode,
                    direction: link == LinkType.wifi ? tabDrives : direction,
                    displayMode:
                        mode == remote ? DisplayMode.mirror : displayMode,
                  ),
                  reason);
              await settings.setLinkType(link);
              expect(of.direction, settings.effectiveRemoteDirection,
                  reason: reason);
              expect(of.displayMode, settings.effectiveDisplayMode,
                  reason: reason);
              expect(of.isReverseRemote, settings.isReverseRemote,
                  reason: reason);
            }
          }
        }
      }
    });

    test('remote control mirrors, whatever display mode is passed', () {
      for (final direction in RemoteDirection.values) {
        for (final link in LinkType.values) {
          for (final displayMode in DisplayMode.values) {
            expect(
                SessionSpec.from(SessionChoice(remote, direction), link,
                        displayMode: displayMode)
                    .displayMode,
                DisplayMode.mirror);
            expect(
                SessionSpec.from(SessionChoice(extended, direction), link,
                        displayMode: displayMode)
                    .displayMode,
                displayMode);
          }
        }
      }
    });

    test('a Wi-Fi session is never reverse', () {
      for (final choice in [
        ...SessionChoice.all,
        const SessionChoice(extended, macDrives),
      ]) {
        final spec = SessionSpec.from(choice, LinkType.wifi,
            displayMode: DisplayMode.extend);
        expect(spec.isReverseRemote, isFalse);
        expect(spec.direction, tabDrives);
        expect(spec.link, LinkType.wifi);
      }
      expect(
          SessionSpec.from(const SessionChoice(remote, macDrives), LinkType.usb,
                  displayMode: DisplayMode.extend)
              .isReverseRemote,
          isTrue);
    });

    test('a USB Extended session carries the saved direction', () async {
      // The direction byte of its 0xF9 is the saved one, as before.
      SharedPreferences.setMockInitialValues({
        'session_mode': 'extendedScreen',
        'remote_direction': 'macControlsTab',
      });
      final settings = SettingsService();
      await settings.init();
      expect(settings.nextChoice, const SessionChoice(extended, macDrives));
      final usb = SessionSpec.of(settings, LinkType.usb);
      expect(usb.mode, extended);
      expect(usb.direction, macDrives);
      expect(usb.direction, settings.remoteDirection);
      expect(usb.isReverseRemote, isFalse);
      expect(SessionSpec.of(settings, LinkType.wifi).direction, tabDrives);
    });

    test('a fresh install\'s next choice is an Extended screen', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      await settings.init();
      expect(settings.nextChoice, const SessionChoice(extended, tabDrives));
    });
  });
}
