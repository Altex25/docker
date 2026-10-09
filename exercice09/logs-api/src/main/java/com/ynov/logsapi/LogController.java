package com.ynov.logsapi;

import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import java.util.List;

@RestController
@RequestMapping("/api/v1/logs")
public class LogController {

    private final LogRepository repository;

    public LogController(LogRepository repository) {
        this.repository = repository;
    }

    // GET /api/v1/logs ou GET /api/v1/logs?level=ERR
    @GetMapping
    public List<LogEntry> findAll(@RequestParam(required = false) LogLevel level) {
        return level == null
                ? repository.findAllByOrderByIdAsc()
                : repository.findByLevelOrderByIdAsc(level);
    }

    @PostMapping
    public ResponseEntity<LogEntry> create(@Valid @RequestBody LogEntry log) {
        log.setId(null);
        return ResponseEntity.status(HttpStatus.CREATED).body(repository.save(log));
    }
}
