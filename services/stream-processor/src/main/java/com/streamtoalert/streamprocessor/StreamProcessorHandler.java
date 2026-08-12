package com.streamtoalert.streamprocessor;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.LambdaLogger;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.DynamodbEvent;
import com.amazonaws.services.lambda.runtime.events.DynamodbEvent.DynamodbStreamRecord;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.Map;
import java.util.Optional;
import software.amazon.awssdk.services.sns.SnsClient;
import software.amazon.awssdk.services.sns.model.PublishRequest;
import software.amazon.awssdk.services.sns.model.PublishResponse;

public class StreamProcessorHandler implements RequestHandler<DynamodbEvent, Void> {

  static final String THRESHOLD_ENV_VAR = "THRESHOLD";
  static final String SNS_TOPIC_ARN_ENV_VAR = "SNS_TOPIC_ARN";
  static final BigDecimal DEFAULT_THRESHOLD = new BigDecimal("10000");

  private final SnsClient snsClient;
  private final String topicArn;
  private final BigDecimal threshold;
  private final ObjectMapper objectMapper = new ObjectMapper();

  /** Used by the Lambda runtime. */
  public StreamProcessorHandler() {
    this(
        SnsClient.create(),
        requireEnv(SNS_TOPIC_ARN_ENV_VAR),
        readThreshold(System.getenv(THRESHOLD_ENV_VAR)));
  }

  StreamProcessorHandler(SnsClient snsClient, String topicArn, BigDecimal threshold) {
    this.snsClient = snsClient;
    this.topicArn = topicArn;
    this.threshold = threshold;
  }

  @Override
  public Void handleRequest(DynamodbEvent event, Context context) {
    LambdaLogger logger = context.getLogger();

    for (DynamodbStreamRecord record : event.getRecords()) {
      if (!"INSERT".equals(record.getEventName())) {
        continue;
      }

      Map<String, com.amazonaws.services.lambda.runtime.events.models.dynamodb.AttributeValue>
          newImage = record.getDynamodb().getNewImage();
      Optional<Transaction> transaction = TransactionParser.parse(newImage);

      if (transaction.isEmpty()) {
        logger.log(
            "Skipping record " + record.getEventID() + ": missing/invalid required fields");
        continue;
      }

      Transaction tx = transaction.get();
      if (tx.amount().compareTo(threshold) <= 0) {
        logger.log("Transaction " + tx.transactionId() + " not notable (amount=" + tx.amount()
            + ", threshold=" + threshold + ")");
        continue;
      }

      publishAlert(tx, logger);
    }

    return null;
  }

  private void publishAlert(Transaction tx, LambdaLogger logger) {
    TransactionAlert alert =
        new TransactionAlert(
            tx.transactionId(),
            tx.accountId(),
            tx.amount(),
            threshold,
            tx.type(),
            "amount " + tx.amount() + " exceeds threshold " + threshold,
            Instant.now().toString());

    String body;
    try {
      body = objectMapper.writeValueAsString(alert);
    } catch (Exception e) {
      throw new RuntimeException("Failed to serialize alert for " + tx.transactionId(), e);
    }

    PublishResponse response =
        snsClient.publish(PublishRequest.builder().topicArn(topicArn).message(body).build());

    logger.log(
        "Published alert for transaction " + tx.transactionId() + " (messageId="
            + response.messageId() + ")");
  }

  private static String requireEnv(String name) {
    String value = System.getenv(name);
    if (value == null || value.isBlank()) {
      throw new IllegalStateException("Missing required environment variable: " + name);
    }
    return value;
  }

  private static BigDecimal readThreshold(String rawValue) {
    return rawValue == null || rawValue.isBlank() ? DEFAULT_THRESHOLD : new BigDecimal(rawValue);
  }
}
