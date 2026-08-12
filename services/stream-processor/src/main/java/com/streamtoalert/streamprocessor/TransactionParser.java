package com.streamtoalert.streamprocessor;

import com.amazonaws.services.lambda.runtime.events.models.dynamodb.AttributeValue;
import java.math.BigDecimal;
import java.util.Map;
import java.util.Optional;

/** Parses a DynamoDB Stream NEW_IMAGE into a {@link Transaction}. */
final class TransactionParser {

  private TransactionParser() {}

  static Optional<Transaction> parse(Map<String, AttributeValue> newImage) {
    if (newImage == null) {
      return Optional.empty();
    }

    String accountId = readString(newImage, "accountId");
    String transactionId = readString(newImage, "transactionId");
    BigDecimal amount = readAmount(newImage, "amount");

    if (accountId == null || transactionId == null || amount == null) {
      return Optional.empty();
    }

    String type = readString(newImage, "type");
    String createdAt = readString(newImage, "createdAt");

    return Optional.of(new Transaction(accountId, transactionId, amount, type, createdAt));
  }

  private static String readString(Map<String, AttributeValue> image, String key) {
    AttributeValue value = image.get(key);
    return value == null ? null : value.getS();
  }

  private static BigDecimal readAmount(Map<String, AttributeValue> image, String key) {
    AttributeValue value = image.get(key);
    if (value == null || value.getN() == null) {
      return null;
    }
    try {
      return new BigDecimal(value.getN());
    } catch (NumberFormatException e) {
      return null;
    }
  }
}
