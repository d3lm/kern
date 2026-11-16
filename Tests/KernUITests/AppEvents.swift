import Testing

/// Runs serially because the panel closes on any click elsewhere in the app, so a test sending events
/// would close the panel another test has open.
@Suite(.serialized) enum AppEvents {}
