package com.ynov.crudapi;

public record LogEntry(String message, String source, String timestamp, String level) {
}
