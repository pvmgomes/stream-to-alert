package com.streamtoalert.streamprocessor;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.LambdaLogger;
import com.amazonaws.services.lambda.runtime.events.DynamodbEvent;
import com.amazonaws.services.lambda.runtime.events.DynamodbEvent.DynamodbStreamRecord;
import com.amazonaws.services.lambda.runtime.events.models.dynamodb.AttributeValue;
import com.amazonaws.services.lambda.runtime.events.models.dynamodb.StreamRecord;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.math.BigDecimal;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import software.amazon.awssdk.services.sns.SnsClient;
import software.amazon.awssdk.services.sns.model.PublishRequest;
import software.amazon.awssdk.services.sns.model.PublishResponse;

@ExtendWith(MockitoExtension.class)
class StreamProcessorHandlerTest {

  private static final String TOPIC_ARN = "arn:aws:sns:us-east-1:000000000000:transaction-alerts";
  private static final BigDecimal THRESHOLD = new BigDecimal("10000");

  @Mock private SnsClient snsClient;
  @Mock private Context context;
  @Mock private LambdaLogger logger;

  private final ObjectMapper objectMapper = new ObjectMapper();
  private StreamProcessorHandler handler;

  @BeforeEach
  void setUp() {
    when(context.getLogger()).thenReturn(logger);
    handler = new StreamProcessorHandler(snsClient, TOPIC_ARN, THRESHOLD);
  }

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

  private static DynamodbStreamRecord insertRecord(Map<String, AttributeValue> newImage) {
    return record("INSERT", newImage);
  }

  private static DynamodbStreamRecord record(String eventName, Map<String, AttributeValue> newImage) {
    StreamRecord streamRecord = new StreamRecord();
    streamRecord.setNewImage(newImage);

    DynamodbStreamRecord record = new DynamodbStreamRecord();
    record.setEventID("evt-1");
    record.setEventName(eventName);
    record.setDynamodb(streamRecord);
    return record;
  }

  private static Map<String, AttributeValue> transactionImage(String amount) {
    Map<String, AttributeValue> image = new HashMap<>();
    image.put("accountId", s("acct-1"));
    image.put("transactionId", s("txn-1"));
    image.put("amount", n(amount));
    image.put("type", s("WITHDRAWAL"));
    return image;
  }

  private void invoke(DynamodbStreamRecord... records) {
    DynamodbEvent event = new DynamodbEvent();
    event.setRecords(List.of(records));
    handler.handleRequest(event, context);
  }

  @Test
  void publishesWhenAmountAboveThreshold() throws Exception {
    when(snsClient.publish(any(PublishRequest.class)))
        .thenReturn(PublishResponse.builder().messageId("msg-1").build());

    invoke(insertRecord(transactionImage("10001")));

    ArgumentCaptor<PublishRequest> captor = ArgumentCaptor.forClass(PublishRequest.class);
    verify(snsClient).publish(captor.capture());

    PublishRequest request = captor.getValue();
    assertThat(request.topicArn()).isEqualTo(TOPIC_ARN);

    JsonNode body = objectMapper.readTree(request.message());
    assertThat(body.get("transactionId").asText()).isEqualTo("txn-1");
    assertThat(body.get("accountId").asText()).isEqualTo("acct-1");
    assertThat(body.get("amount").asText()).isEqualTo("10001");
    assertThat(body.get("threshold").asText()).isEqualTo("10000");
    assertThat(body.get("type").asText()).isEqualTo("WITHDRAWAL");
    assertThat(body.get("reason").asText()).contains("10001").contains("10000");
    assertThat(body.get("alertedAt").asText()).isNotBlank();
  }

  @Test
  void omitsTypeFromPayloadWhenAbsentOnSourceItem() throws Exception {
    when(snsClient.publish(any(PublishRequest.class)))
        .thenReturn(PublishResponse.builder().messageId("msg-1").build());

    Map<String, AttributeValue> image = transactionImage("10001");
    image.remove("type");

    invoke(insertRecord(image));

    ArgumentCaptor<PublishRequest> captor = ArgumentCaptor.forClass(PublishRequest.class);
    verify(snsClient).publish(captor.capture());

    JsonNode body = objectMapper.readTree(captor.getValue().message());
    assertThat(body.has("type")).isFalse();
  }

  @Test
  void doesNotPublishWhenAmountBelowThreshold() {
    invoke(insertRecord(transactionImage("9999")));

    verify(snsClient, never()).publish(any(PublishRequest.class));
  }

  @Test
  void doesNotPublishWhenAmountExactlyAtThreshold() {
    invoke(insertRecord(transactionImage("10000")));

    verify(snsClient, never()).publish(any(PublishRequest.class));
  }

  @Test
  void ignoresNonInsertEvents() {
    invoke(record("MODIFY", transactionImage("50000")));

    verify(snsClient, never()).publish(any(PublishRequest.class));
  }

  @Test
  void skipsMalformedRecordWithoutThrowing() {
    Map<String, AttributeValue> image = transactionImage("10001");
    image.remove("amount");

    invoke(insertRecord(image));

    verify(snsClient, never()).publish(any(PublishRequest.class));
  }
}
