package com.ynov.crudapi;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.HandlerInterceptor;
import java.time.Instant;

@Component
public class LoggingInterceptor implements HandlerInterceptor {

    public static final String ERROR_MESSAGE = "crudapi.errorMessage";
    public static final String ERROR_TIMESTAMP = "crudapi.errorTimestamp";
    private static final int MAX_MESSAGE_LENGTH = 2000;

    private final LogClient logClient;

    public LoggingInterceptor(LogClient logClient) {
        this.logClient = logClient;
    }

    @Override
    public void afterCompletion(HttpServletRequest request, HttpServletResponse response,
                                Object handler, Exception ex) {
        int status = response.getStatus();

        String level = status >= 500 ? "ERR" : status >= 400 ? "WARN" : "INFO";

        Object errorMessage = request.getAttribute(ERROR_MESSAGE);
        String message = errorMessage != null ? errorMessage.toString() : "HTTP " + status;
        if (message.length() > MAX_MESSAGE_LENGTH) {
            message = message.substring(0, MAX_MESSAGE_LENGTH);
        }

        Object errorTimestamp = request.getAttribute(ERROR_TIMESTAMP);
        String timestamp = errorTimestamp != null ? errorTimestamp.toString() : Instant.now().toString();

        String source = "[CrudAPI] " + request.getMethod() + " " + request.getRequestURI();

        logClient.send(new LogEntry(message, source, timestamp, level));
    }
}
