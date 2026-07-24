package com.streamtoalert.streamprocessor;

import static org.assertj.core.api.Assertions.assertThat;

import com.amazonaws.services.lambda.runtime.events.models.dynamodb.AttributeValue;
import java.math.BigDecimal;
import java.util.HashMap;
import java.util.Map;
import java.util.Optional;
import org.junit.jupiter.api.Test;

class TransactionParserTest {

  private static AttributeValue s(String value) {
    AttributeValue av = new AttributeValue();
    av.setS(value);
    return av;
  }

  private static AttributeValue n(String value) {
    AttributeValue av = new AttributeValue();
    av.setN(value);
    return av;
  }

  @Test
  void parsesWellFormedRecordWithOptionalFields() {
    Map<String, AttributeValue> image = new HashMap<>();
    image.put("accountId", s("acct-1"));
    image.put("transactionId", s("txn-1"));
    image.put("amount", n("12345.67"));
    image.put("type", s("WITHDRAWAL"));
    image.put("createdAt", s("2026-07-24T21:00:00Z"));

    Optional<Transaction> result = TransactionParser.parse(image);

    assertThat(result).isPresent();
    Transaction tx = result.get();
    assertThat(tx.accountId()).isEqualTo("acct-1");
    assertThat(tx.transactionId()).isEqualTo("txn-1");
    assertThat(tx.amount()).isEqualByComparingTo(new BigDecimal("12345.67"));
    assertThat(tx.type()).isEqualTo("WITHDRAWAL");
    assertThat(tx.createdAt()).isEqualTo("2026-07-24T21:00:00Z");
  }

  @Test
  void parsesWellFormedRecordWithoutOptionalFields() {
    Map<String, AttributeValue> image = new HashMap<>();
    image.put("accountId", s("acct-1"));
    image.put("transactionId", s("txn-1"));
    image.put("amount", n("500"));

    Optional<Transaction> result = TransactionParser.parse(image);

    assertThat(result).isPresent();
    assertThat(result.get().type()).isNull();
    assertThat(result.get().createdAt()).isNull();
  }

  @Test
  void missingAmountIsSkipped() {
    Map<String, AttributeValue> image = new HashMap<>();
    image.put("accountId", s("acct-1"));
    image.put("transactionId", s("txn-1"));

    assertThat(TransactionParser.parse(image)).isEmpty();
  }

  @Test
  void nonNumericAmountIsSkipped() {
    Map<String, AttributeValue> image = new HashMap<>();
    image.put("accountId", s("acct-1"));
    image.put("transactionId", s("txn-1"));
    image.put("amount", n("not-a-number"));

    assertThat(TransactionParser.parse(image)).isEmpty();
  }

  @Test
  void missingKeyAttributesIsSkipped() {
    Map<String, AttributeValue> image = new HashMap<>();
    image.put("amount", n("500"));

    assertThat(TransactionParser.parse(image)).isEmpty();
  }

  @Test
  void nullImageIsSkipped() {
    assertThat(TransactionParser.parse(null)).isEmpty();
  }
}
