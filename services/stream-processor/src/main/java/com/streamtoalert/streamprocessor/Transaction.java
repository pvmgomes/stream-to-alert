package com.streamtoalert.streamprocessor;

import java.math.BigDecimal;

public record Transaction(
    String accountId,
    String transactionId,
    BigDecimal amount,
    String type,
    String createdAt) {}
