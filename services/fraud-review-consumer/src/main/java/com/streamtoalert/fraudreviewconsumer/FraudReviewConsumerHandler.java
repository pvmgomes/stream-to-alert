package com.streamtoalert.fraudreviewconsumer;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.LambdaLogger;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.SQSBatchResponse;
import com.amazonaws.services.lambda.runtime.events.SQSBatchResponse.BatchItemFailure;
import com.amazonaws.services.lambda.runtime.events.SQSEvent;
import com.amazonaws.services.lambda.runtime.events.SQSEvent.SQSMessage;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;

public class FraudReviewConsumerHandler implements RequestHandler<SQSEvent, SQSBatchResponse> {

  static final String TABLE_NAME_ENV_VAR = "TABLE_NAME";

  private final DynamoDbClient dynamoDbClient;
  private final String tableName;
  private final ObjectMapper objectMapper = new ObjectMapper();

  /** Used by the Lambda runtime. */
  public FraudReviewConsumerHandler() {
    this(DynamoDbClient.create(), requireEnv(TABLE_NAME_ENV_VAR));
  }

  FraudReviewConsumerHandler(DynamoDbClient dynamoDbClient, String tableName) {
    this.dynamoDbClient = dynamoDbClient;
    this.tableName = tableName;
  }

  @Override
  public SQSBatchResponse handleRequest(SQSEvent event, Context context) {
    LambdaLogger logger = context.getLogger();
    List<BatchItemFailure> failures = new ArrayList<>();

    for (SQSMessage message : event.getRecords()) {
      Optional<IncomingAlert> alert = AlertParser.parse(objectMapper, message.getBody());

      if (alert.isEmpty()) {
        logger.log("Skipping message " + message.getMessageId() + ": invalid alert payload");
        failures.add(new BatchItemFailure(message.getMessageId()));
        continue;
      }

      try {
        writeCase(alert.get());
        logger.log("Wrote fraud review case for transaction " + alert.get().transactionId());
      } catch (Exception e) {
        logger.log(
            "Failed to write case for transaction " + alert.get().transactionId() + ": "
                + e.getMessage());
        failures.add(new BatchItemFailure(message.getMessageId()));
      }
    }

    return SQSBatchResponse.builder().withBatchItemFailures(failures).build();
  }

  private void writeCase(IncomingAlert alert) {
    dynamoDbClient.putItem(
        PutItemRequest.builder()
            .tableName(tableName)
            .item(
                Map.of(
                    "transactionId", AttributeValue.fromS(alert.transactionId()),
                    "accountId", AttributeValue.fromS(alert.accountId()),
                    "amount", AttributeValue.fromN(alert.amount().toPlainString()),
                    "reason", AttributeValue.fromS(alert.reason()),
                    "alertedAt", AttributeValue.fromS(alert.alertedAt())))
            .build());
  }

  private static String requireEnv(String name) {
    String value = System.getenv(name);
    if (value == null || value.isBlank()) {
      throw new IllegalStateException("Missing required environment variable: " + name);
    }
    return value;
  }
}
