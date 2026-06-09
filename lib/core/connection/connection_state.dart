enum ConnectionPhase {
  disconnected,
  detectingDevice,
  adbConnecting,
  portForwarding,
  handshaking,
  configuring,
  streaming,
  paused,
  error,
}

extension ConnectionPhaseX on ConnectionPhase {
  bool get isActive =>
      this == ConnectionPhase.streaming || this == ConnectionPhase.paused;

  bool get isConnecting =>
      this != ConnectionPhase.disconnected &&
      this != ConnectionPhase.streaming &&
      this != ConnectionPhase.paused &&
      this != ConnectionPhase.error;

  String get label => switch (this) {
        ConnectionPhase.disconnected => 'Disconnected',
        ConnectionPhase.detectingDevice => 'Detecting device…',
        ConnectionPhase.adbConnecting => 'Connecting via ADB…',
        ConnectionPhase.portForwarding => 'Forwarding port…',
        ConnectionPhase.handshaking => 'Handshaking…',
        ConnectionPhase.configuring => 'Configuring display…',
        ConnectionPhase.streaming => 'Streaming',
        ConnectionPhase.paused => 'Paused',
        ConnectionPhase.error => 'Error',
      };
}
