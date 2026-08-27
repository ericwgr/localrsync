import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/pages/language_page.dart';
import 'package:localsend_app/pages/tabs/settings_tab_vm.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/autostart_helper.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart';
import 'package:localsend_app/util/native/context_menu_helper.dart';
import 'package:localsend_app/util/native/macos_channel.dart';
import 'package:localsend_app/util/ui/dynamic_colors.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/widget/dialogs/custom_color_dialog.dart';
import 'package:localsend_app/widget/dialogs/storage_permission_dialog.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/util/sleep.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

final settingsTabControllerProvider = ReduxProvider<SettingsTabController, SettingsTabVm>((ref) {
  final settings = ref.notifier(settingsProvider);
  final server = ref.notifier(serverProvider);
  final isolateController = ref.notifier(parentIsolateProvider);
  final localIpService = ref.notifier(localIpProvider);
  final initialDeviceInfo = ref.read(deviceInfoProvider);
  final supportsDynamicColors = ref.read(dynamicColorsProvider) != null;

  return SettingsTabController(
    settingsService: settings,
    serverNotifier: server,
    isolateController: isolateController,
    localIpService: localIpService,
    initialDeviceInfo: initialDeviceInfo,
    supportsDynamicColors: supportsDynamicColors,
  );
});

class SettingsTabController extends ReduxNotifier<SettingsTabVm> {
  final SettingsService _settingsService;
  final ServerService _serverService;
  final IsolateController _isolateController;
  final LocalIpService _localIpService;
  final DeviceInfoResult _initialDeviceInfo;
  final bool _supportsDynamicColors;

  /// Whether the permission guidance dialog was already shown in this app run,
  /// so that it does not pop up again while the permission is still missing.
  bool _permissionPromptedThisSession = false;

  SettingsTabController({
    required SettingsService settingsService,
    required ServerService serverNotifier,
    required IsolateController isolateController,
    required LocalIpService localIpService,
    required DeviceInfoResult initialDeviceInfo,
    required bool supportsDynamicColors,
  }) : _settingsService = settingsService,
       _serverService = serverNotifier,
       _isolateController = isolateController,
       _localIpService = localIpService,
       _initialDeviceInfo = initialDeviceInfo,
       _supportsDynamicColors = supportsDynamicColors;

  @override
  SettingsTabVm init() {
    // Keep the state in sync when the user returns from System Settings after
    // granting (or revoking) Full Disk Access.
    if (Platform.isMacOS) {
      fullDiskAccessStream.listen((granted) {
        redux.dispatch(_SetFullDiskAccessGrantedAction(granted));
      });
    }

    return SettingsTabVm(
      advanced: _settingsService.state.advancedSettings,
      aliasController: TextEditingController(text: _settingsService.state.alias),
      deviceModelController: TextEditingController(text: _initialDeviceInfo.deviceModel),
      portController: TextEditingController(text: _settingsService.state.port.toString()),
      timeoutController: TextEditingController(text: _settingsService.state.discoveryTimeout.toString()),
      multicastController: TextEditingController(text: _settingsService.state.multicastGroup),
      settings: _settingsService.state,
      serverState: _serverService.state,
      deviceInfo: _initialDeviceInfo,
      colorModes: _supportsDynamicColors ? ColorMode.values : ColorMode.values.where((e) => e != ColorMode.system).toList(),
      autoStart: false,
      autoStartLaunchHidden: false,
      showInContextMenu: false,
      allFilesAccessGranted: false,
      fullDiskAccessGranted: false,
      onChangeTheme: (context, theme) async {
        await _settingsService.setTheme(theme);
        await sleepAsync(500); // workaround: brightness takes some time to be updated
        if (context.mounted) {
          await updateSystemOverlayStyle(context);
        }
      },
      onChangeColorMode: (context, colorMode) async {
        if (colorMode == ColorMode.custom) {
          final color = await showDialog<Color>(
            context: context,
            builder: (_) => CustomColorDialog(initialColor: _settingsService.state.customColor),
          );
          if (color == null) {
            return;
          }
          await _settingsService.setCustomColor(color);
        }
        await _settingsService.setColorMode(colorMode);
        if (colorMode == ColorMode.oled) {
          await _settingsService.setTheme(ThemeMode.dark);
          await updateSystemOverlayStyleWithBrightness(Brightness.dark);
        }
      },
      onTapLanguage: (context) async {
        await context.push(() => const LanguagePage());
      },
      onToggleAutoStart: (context) async {
        final bool success;
        if (state.autoStart) {
          success = await disableAutoStart();
        } else {
          success = await enableAutoStart(startHidden: state.autoStartLaunchHidden);
        }

        if (success) {
          redux.dispatch(_SetAutoStartAction(!state.autoStart));
        }
      },
      onToggleAutoStartLaunchHidden: (context) async {
        if (state.autoStart) {
          final success = await enableAutoStart(startHidden: !state.autoStartLaunchHidden);
          if (success) {
            redux.dispatch(_SetAutoStartLaunchHiddenAction(!state.autoStartLaunchHidden));
          }
        }
      },
      onToggleShowInContextMenu: (context) async {
        final bool success;
        if (state.showInContextMenu) {
          success = await disableContextMenu();
        } else {
          success = await enableContextMenu();
        }
        if (success) {
          redux.dispatch(_SetShowInContextMenuAction(!state.showInContextMenu));
        }
      },
      onTapRestartServer: (context) async {
        try {
          final newServerState = await _serverService.restartServer(
            alias: _settingsService.state.alias,
            port: _settingsService.state.port,
            https: _settingsService.state.https,
          );

          if (newServerState != null) {
            // the new state is always valid, so we can "repair" user's setting
            state.aliasController.text = newServerState.alias;
            state.portController.text = newServerState.port.toString();
            await _settingsService.setAlias(newServerState.alias);
            await _settingsService.setPort(newServerState.port);
            external(_isolateController).dispatch(IsolateDiscoveryRestartAction());
            external(_localIpService).dispatchAsync(FetchLocalIpAction()); // ignore: unawaited_futures
          }
        } catch (e) {
          // ignore: use_build_context_synchronously
          context.showSnackBar(e.toString());
        }
      },
      onTapStartServer: (context) async {
        try {
          await _serverService.startServerFromSettings();
        } catch (e) {
          // ignore: use_build_context_synchronously
          context.showSnackBar(e.toString());
        }
      },
      onTapStopServer: () async => await _serverService.stopServer(),
      onTapAdvanced: (advanced) => redux.dispatch(SetAdvancedAction(advanced)),
      onTabEntered: _checkOnTabEntered,
      onCheckPermission: _checkOrRequestPermission,
    );
  }

  /// Whether the file access permission of the current platform
  /// has been granted. Meaningless on other platforms (returns true).
  bool get _currentPlatformPermissionGranted {
    if (Platform.isAndroid) {
      return state.allFilesAccessGranted;
    }
    if (Platform.isMacOS) {
      return state.fullDiskAccessGranted;
    }
    return true;
  }

  /// Re-reads the file access permission of the current platform from the OS
  /// and mirrors it into the VM.
  Future<bool> _refreshPermissionState() async {
    if (Platform.isAndroid) {
      final granted = await hasAllFilesAccessPermissionAndroid();
      redux.dispatch(_SetAllFilesAccessGrantedAction(granted));
      return granted;
    }
    if (Platform.isMacOS) {
      final granted = await hasFullDiskAccessMacOs();
      redux.dispatch(_SetFullDiskAccessGrantedAction(granted));
      return granted;
    }
    return true;
  }

  /// Android: opens the "All files access" system screen and resolves with the
  /// granted state once the user returns. macOS: opens the Full Disk Access pane
  /// in System Settings (resolves immediately, the state is re-checked separately).
  Future<bool> _openPermissionSettings() async {
    if (Platform.isAndroid) {
      final granted = await requestAllFilesAccessPermissionAndroid();
      redux.dispatch(_SetAllFilesAccessGrantedAction(granted));
      return granted;
    }
    if (Platform.isMacOS) {
      await openFullDiskAccessSettings();
      return false;
    }
    return true;
  }

  /// Called when the settings tab becomes visible: re-checks the file access
  /// permission and shows a guided dialog when it is missing (once per app run).
  Future<void> _checkOnTabEntered(BuildContext context) async {
    final granted = await _refreshPermissionState();
    if (!context.mounted || granted || _permissionPromptedThisSession) {
      return;
    }
    _permissionPromptedThisSession = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => StoragePermissionDialog(
        isAndroid: Platform.isAndroid,
        onOpenSettings: _openPermissionSettings,
        onRecheck: _refreshPermissionState,
      ),
    );
  }

  /// Triggered by the permission entry rows: opens/requests the system settings
  /// when not granted, or silently re-checks when already granted.
  Future<void> _checkOrRequestPermission(BuildContext context) async {
    if (_currentPlatformPermissionGranted) {
      await _refreshPermissionState();
    } else {
      await _openPermissionSettings();
    }
  }

  @override
  get initialAction => _SettingsTabInitAction();

  @override
  void dispose() {
    state.aliasController.dispose();
    state.deviceModelController.dispose();
    state.portController.dispose();
    state.timeoutController.dispose();
    state.multicastController.dispose();
    super.dispose();
  }
}

class _SettingsTabInitAction extends AsyncReduxAction<SettingsTabController, SettingsTabVm> {
  @override
  Future<SettingsTabVm> reduce() async {
    dispatch(_SettingsTabWatchAction());
    final autoStartEnabled = await isAutoStartEnabled();
    final autoStartHidden = await isAutoStartHidden();
    final showInContextMenu = await isContextMenuEnabled();
    final allFilesAccessGranted = Platform.isAndroid ? await hasAllFilesAccessPermissionAndroid() : false;
    final fullDiskAccessGranted = Platform.isMacOS ? await hasFullDiskAccessMacOs() : false;
    return state.copyWith(
      autoStart: autoStartEnabled,
      autoStartLaunchHidden: autoStartHidden,
      showInContextMenu: showInContextMenu,
      allFilesAccessGranted: allFilesAccessGranted,
      fullDiskAccessGranted: fullDiskAccessGranted,
    );
  }
}

class _SettingsTabWatchAction extends WatchAction<SettingsTabController, SettingsTabVm> {
  @override
  SettingsTabVm reduce() {
    return state.copyWith(
      settings: ref.watch(settingsProvider),
      serverState: ref.watch(serverProvider),
      deviceInfo: ref.watch(deviceInfoProvider),
    );
  }
}

class SetAdvancedAction extends ReduxAction<SettingsTabController, SettingsTabVm> {
  final bool advanced;

  SetAdvancedAction(this.advanced);

  @override
  SettingsTabVm reduce() {
    return state.copyWith(advanced: advanced);
  }
}

class _SetAutoStartAction extends ReduxAction<SettingsTabController, SettingsTabVm> {
  final bool enabled;

  _SetAutoStartAction(this.enabled);

  @override
  SettingsTabVm reduce() {
    return state.copyWith(autoStart: enabled);
  }
}

class _SetAutoStartLaunchHiddenAction extends ReduxAction<SettingsTabController, SettingsTabVm> {
  final bool enabled;

  _SetAutoStartLaunchHiddenAction(this.enabled);

  @override
  SettingsTabVm reduce() {
    return state.copyWith(autoStartLaunchHidden: enabled);
  }
}

class _SetShowInContextMenuAction extends ReduxAction<SettingsTabController, SettingsTabVm> {
  final bool enabled;

  _SetShowInContextMenuAction(this.enabled);

  @override
  SettingsTabVm reduce() {
    return state.copyWith(showInContextMenu: enabled);
  }
}

class _SetAllFilesAccessGrantedAction extends ReduxAction<SettingsTabController, SettingsTabVm> {
  final bool granted;

  _SetAllFilesAccessGrantedAction(this.granted);

  @override
  SettingsTabVm reduce() {
    return state.copyWith(allFilesAccessGranted: granted);
  }
}

class _SetFullDiskAccessGrantedAction extends ReduxAction<SettingsTabController, SettingsTabVm> {
  final bool granted;

  _SetFullDiskAccessGrantedAction(this.granted);

  @override
  SettingsTabVm reduce() {
    return state.copyWith(fullDiskAccessGranted: granted);
  }
}
