package com.ynov.logsapi;

import jakarta.persistence.*;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

@Entity
@Table(name = "logs")
public class LogEntry {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @NotBlank
    @Column(nullable = false, length = 2000)
    private String message;

    @NotBlank
    @Column(nullable = false, length = 500)
    private String source;

    @NotBlank
    @Column(nullable = false)
    private String timestamp;

    @NotNull
    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 4)
    private LogLevel level;

    public Long getId() { return id; }
    public void setId(Long id) { this.id = id; }

    public String getMessage() { return message; }
    public void setMessage(String message) { this.message = message; }

    public String getSource() { return source; }
    public void setSource(String source) { this.source = source; }

    public String getTimestamp() { return timestamp; }
    public void setTimestamp(String timestamp) { this.timestamp = timestamp; }

    public LogLevel getLevel() { return level; }
    public void setLevel(LogLevel level) { this.level = level; }
}
