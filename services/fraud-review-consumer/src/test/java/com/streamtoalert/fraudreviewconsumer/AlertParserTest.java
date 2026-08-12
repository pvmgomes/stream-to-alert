package com.streamtoalert.fraudreviewconsumer;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.math.BigDecimal;
import java.util.Optional;
import org.junit.jupiter.api.Test;

class AlertParserTest {

  private final ObjectMapper objectMapper = new ObjectMapper();

  @Test
  void parsesWellFormedAlert() {
    String body =
        """
        {
          "transactionId": "txn-1",
          "accountId": "acct-1",
          "amount": 15000,
          "threshold": 10000,
          "type": "WITHDRAWAL",
          "reason": "amount 15000 exceeds threshold 10000",
          "alertedAt": "2026-07-24T21:00:00Z"
        }
        """;

    Optional<IncomingAlert> result = AlertParser.parse(objectMapper, body);

    assertThat(result).isPresent();
    IncomingAlert alert = result.get();
    assertThat(alert.transactionId()).isEqualTo("txn-1");
    assertThat(alert.accountId()).isEqualTo("acct-1");
    assertThat(alert.amount()).isEqualByComparingTo(new BigDecimal("15000"));
    assertThat(alert.reason()).isEqualTo("amount 15000 exceeds threshold 10000");
    assertThat(alert.alertedAt()).isEqualTo("2026-07-24T21:00:00Z");
  }

  @Test
  void ignoresUnknownFieldsLikeThresholdAndType() {
    String body =
        """
        {
          "transactionId": "txn-1",
          "accountId": "acct-1",
          "amount": 15000,
          "threshold": 10000,
          "type": "WITHDRAWAL",
          "reason": "amount 15000 exceeds threshold 10000",
          "alertedAt": "2026-07-24T21:00:00Z",
          "somethingElseEntirely": "should not break parsing"
        }
        """;

    assertThat(AlertParser.parse(objectMapper, body)).isPresent();
  }

  @Test
  void missingRequiredFieldIsRejected() {
    String body =
        """
        {
          "transactionId": "txn-1",
          "accountId": "acct-1",
          "amount": 15000,
          "alertedAt": "2026-07-24T21:00:00Z"
        }
        """;

    assertThat(AlertParser.parse(objectMapper, body)).isEmpty();
  }

  @Test
  void malformedJsonIsRejected() {
    assertThat(AlertParser.parse(objectMapper, "not json at all")).isEmpty();
  }
}
