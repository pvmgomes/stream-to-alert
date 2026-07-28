package com.streamtoalert.fraudreviewconsumer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.LambdaLogger;
import com.amazonaws.services.lambda.runtime.events.SQSBatchResponse;
import com.amazonaws.services.lambda.runtime.events.SQSEvent;
import com.amazonaws.services.lambda.runtime.events.SQSEvent.SQSMessage;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;

@ExtendWith(MockitoExtension.class)
class FraudReviewConsumerHandlerTest {

  private static final String TABLE_NAME = "FraudReviewCases";

  @Mock private DynamoDbClient dynamoDbClient;
  @Mock private Context context;
  @Mock private LambdaLogger logger;

  private FraudReviewConsumerHandler handler;

  @BeforeEach
  void setUp() {
    when(context.getLogger()).thenReturn(logger);
    handler = new FraudReviewConsumerHandler(dynamoDbClient, TABLE_NAME);
  }

  private static SQSMessage message(String messageId, String body) {
    SQSMessage message = new SQSMessage();
    message.setMessageId(messageId);
    message.setBody(body);
    return message;
  }

  private static String validAlertBody() {
    return """
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
  }

  private SQSBatchResponse invoke(SQSMessage... messages) {
    SQSEvent event = new SQSEvent();
    event.setRecords(List.of(messages));
    return handler.handleRequest(event, context);
  }

  @Test
  void writesCaseAndReportsNoFailuresForValidMessage() {
    SQSBatchResponse response = invoke(message("msg-1", validAlertBody()));

    assertThat(response.getBatchItemFailures()).isEmpty();

    ArgumentCaptor<PutItemRequest> captor = ArgumentCaptor.forClass(PutItemRequest.class);
    verify(dynamoDbClient).putItem(captor.capture());

    PutItemRequest request = captor.getValue();
    assertThat(request.tableName()).isEqualTo(TABLE_NAME);
    assertThat(request.item().get("transactionId").s()).isEqualTo("txn-1");
    assertThat(request.item().get("accountId").s()).isEqualTo("acct-1");
    assertThat(request.item().get("amount").n()).isEqualTo("15000");
    assertThat(request.item().get("reason").s())
        .isEqualTo("amount 15000 exceeds threshold 10000");
    assertThat(request.item().get("alertedAt").s()).isEqualTo("2026-07-24T21:00:00Z");
    assertThat(request.item()).doesNotContainKey("threshold");
    assertThat(request.item()).doesNotContainKey("type");
  }

  @Test
  void reportsBatchFailureForMalformedMessageWithoutWriting() {
    SQSBatchResponse response = invoke(message("msg-bad", "not json at all"));

    assertThat(response.getBatchItemFailures()).extracting("itemIdentifier").containsExactly(
        "msg-bad");
    verify(dynamoDbClient, never()).putItem(any(PutItemRequest.class));
  }

  @Test
  void reportsBatchFailureWhenPutItemThrows() {
    when(dynamoDbClient.putItem(any(PutItemRequest.class)))
        .thenThrow(new RuntimeException("simulated DynamoDB failure"));

    SQSBatchResponse response = invoke(message("msg-1", validAlertBody()));

    assertThat(response.getBatchItemFailures()).extracting("itemIdentifier").containsExactly(
        "msg-1");
  }

  @Test
  void onlyFailingMessageIsReportedInAMixedBatch() {
    SQSBatchResponse response =
        invoke(message("msg-good", validAlertBody()), message("msg-bad", "not json at all"));

    assertThat(response.getBatchItemFailures()).extracting("itemIdentifier").containsExactly(
        "msg-bad");
    verify(dynamoDbClient).putItem(any(PutItemRequest.class));
  }
}
