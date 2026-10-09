package com.ynov.crudapi;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClientException;
import org.springframework.web.client.RestTemplate;

@Component
public class LogClient {

    private static final Logger LOGGER = LoggerFactory.getLogger(LogClient.class);

    private final RestTemplate restTemplate = new RestTemplate();
    private final String logsApiUrl;

    public LogClient(@Value("${logs.api.url}") String logsApiUrl) {
        this.logsApiUrl = logsApiUrl;
    }

    public void send(LogEntry entry) {
        try {
            restTemplate.postForEntity(logsApiUrl + "/api/v1/logs", entry, Void.class);
        } catch (RestClientException e) {
            // L'indisponibilité de l'API Logs ne doit pas faire échouer l'API CRUD
            LOGGER.warn("Logs API unreachable ({}): {}", logsApiUrl, e.getMessage());
        }
    }
}
