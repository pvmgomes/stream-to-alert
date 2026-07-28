package com.streamtoalert.fraudreviewconsumer;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.Optional;

/** Parses an SQS message body (raw alert JSON) into an {@link IncomingAlert}. */
final class AlertParser {

  private AlertParser() {}

  static Optional<IncomingAlert> parse(ObjectMapper objectMapper, String body) {
    IncomingAlert alert;
    try {
      alert = objectMapper.readValue(body, IncomingAlert.class);
    } catch (Exception e) {
      return Optional.empty();
    }

    if (isBlank(alert.transactionId())
        || isBlank(alert.accountId())
        || alert.amount() == null
        || isBlank(alert.reason())
        || isBlank(alert.alertedAt())) {
      return Optional.empty();
    }

    return Optional.of(alert);
  }

  private static boolean isBlank(String value) {
    return value == null || value.isBlank();
  }
}
