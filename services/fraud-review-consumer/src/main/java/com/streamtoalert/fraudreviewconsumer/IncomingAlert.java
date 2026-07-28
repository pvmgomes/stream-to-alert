package com.streamtoalert.fraudreviewconsumer;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import java.math.BigDecimal;

/**
 * The alert JSON published by stream-processor. Only the fields this consumer persists are
 * declared; {@code threshold} and {@code type} are present upstream but ignored here.
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public record IncomingAlert(
    String transactionId, String accountId, BigDecimal amount, String reason, String alertedAt) {}
