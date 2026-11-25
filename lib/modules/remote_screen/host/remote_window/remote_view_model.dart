import 'dart:convert';

/// How a toolbar item of a native remote window is drawn.
enum RemoteItemKind {
  /// A button: an SF Symbol, sends its [RemoteToolbarItem.id] as an action.
  button,

  /// A chip: a symbol and optional text in a colour, with a tooltip; sends
  /// nothing.
  chip,

  /// A button that opens a menu of [RemoteToolbarItem.menu] entries, each
  /// sending its own id.
  menu,
}

/// An item's tint: `warn` is the orange of a command the device refused.
enum RemoteTint { normal, warn }

/// A chip's colour.
enum RemoteChipColor { green, orange }

/// One entry of a `menu` item.
class RemoteMenuEntry {
  const RemoteMenuEntry({required this.id, required this.label});
  final String id;
  final String label;

  Map<String, Object?> toMap() => {'id': id, 'label': label};
}

/// One item of a remote window's toolbar (Swift places it in the titlebar
/// accessory). [symbol] is an SF Symbol name; [tooltip] and [text] are
/// already translated; [shortcut] is the key that with ⌘ sends [id].
class RemoteToolbarItem {
  const RemoteToolbarItem({
    required this.id,
    required this.symbol,
    this.tooltip = '',
    this.enabled = true,
    this.tint = RemoteTint.normal,
    this.kind = RemoteItemKind.button,
    this.shortcut,
    this.text,
    this.color,
    this.menu,
  });

  final String id;
  final String symbol;
  final String tooltip;
  final bool enabled;
  final RemoteTint tint;
  final RemoteItemKind kind;
  final String? shortcut;
  final String? text;
  final RemoteChipColor? color;
  final List<RemoteMenuEntry>? menu;

  Map<String, Object?> toMap() => {
    'id': id,
    'symbol': symbol,
    'tooltip': tooltip,
    'enabled': enabled,
    'tint': tint.name,
    'kind': kind.name,
    'shortcut': ?shortcut,
    'text': ?text,
    'color': ?color?.name,
    if (menu != null) 'menu': [for (final e in menu!) e.toMap()],
  };
}

/// The message shown instead of the picture, with an optional action
/// button (its id is sent as an action). With [passThrough] it lies
/// translucent over the last picture instead of hiding it, and takes no
/// clicks but its button's.
class RemoteMessage {
  const RemoteMessage({
    required this.text,
    this.action,
    this.passThrough = false,
  });
  final String text;
  final RemoteMenuEntry? action;
  final bool passThrough;

  /// [passThrough] is sent only when set (Swift reads its absence as
  /// false), so a default message's map is what it always was.
  Map<String, Object?> toMap() => {
    'text': text,
    if (action != null) 'action': action!.toMap(),
    if (passThrough) 'passThrough': true,
  };
}

/// Everything a remote window shows around its picture, as one full
/// snapshot with every string resolved (Swift holds none): the title, the
/// toolbar, a banner over the picture, a message instead of it, and
/// overlay lines in a corner. Sent as `render {id, vm}` ([toMap]); two
/// snapshots with equal maps draw the same, so an equal one is not sent
/// again ([sameAs]).
class RemoteViewModel {
  const RemoteViewModel({
    required this.title,
    this.toolbar = const [],
    this.banner,
    this.message,
    this.overlay,
    this.more,
    this.symbol = defaultSymbol,
  });

  /// The message's symbol when none is given (what Swift also falls back
  /// to).
  static const defaultSymbol = 'iphone';

  final String title;
  final List<RemoteToolbarItem> toolbar;
  final String? banner;
  final RemoteMessage? message;
  final List<String>? overlay;

  /// The label (tooltip) of the one menu Swift folds the toolbar's buttons
  /// and menus into when the titlebar is too narrow for them.
  final String? more;

  /// The SF Symbol the message shows above its text (`ipad.landscape` for a
  /// tablet). Sent only when it is not [defaultSymbol], so a default
  /// snapshot's map is what it always was.
  final String symbol;

  /// The item with [id]; null with none.
  RemoteToolbarItem? item(String id) {
    for (final i in toolbar) {
      if (i.id == id) return i;
    }
    return null;
  }

  Map<String, Object?> toMap() => {
    'title': title,
    'toolbar': [for (final i in toolbar) i.toMap()],
    'banner': ?banner,
    if (message != null) 'message': message!.toMap(),
    'overlay': ?overlay,
    'more': ?more,
    if (symbol != defaultSymbol) 'symbol': symbol,
  };

  /// [toMap] as one string, keys in a fixed order: what dedupes renders.
  String get signature => jsonEncode(toMap());

  bool sameAs(RemoteViewModel? other) =>
      other != null && other.signature == signature;
}
