package com.streamtoalert.streamprocessor;

import com.fasterxml.jackson.annotation.JsonInclude;
import java.math.BigDecimal;

@JsonInclude(JsonInclude.Include.NON_NULL)
public record TransactionAlert(
    String transactionId,
    String accountId,
    BigDecimal amount,
    BigDecimal threshold,
    String type,
    String reason,
    String alertedAt) {}
