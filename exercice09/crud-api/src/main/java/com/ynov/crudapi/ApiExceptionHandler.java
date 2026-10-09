package com.ynov.crudapi;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.ErrorResponse;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;
import java.time.Instant;
import java.util.stream.Collectors;

@RestControllerAdvice
public class ApiExceptionHandler {

    @ExceptionHandler(DogNotFoundException.class)
    public ResponseEntity<ApiError> handleNotFound(DogNotFoundException ex, HttpServletRequest request) {
        return build(request, 404, ex.getMessage());
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<ApiError> handleValidation(MethodArgumentNotValidException ex, HttpServletRequest request) {
        String message = ex.getBindingResult().getFieldErrors().stream()
                .map(error -> error.getField() + ": " + error.getDefaultMessage())
                .collect(Collectors.joining(", "));
        return build(request, 400, "Validation failed - " + message);
    }

    @ExceptionHandler(HttpMessageNotReadableException.class)
    public ResponseEntity<ApiError> handleUnreadable(HttpMessageNotReadableException ex, HttpServletRequest request) {
        return build(request, 400, "Malformed JSON request body");
    }

    @ExceptionHandler(MethodArgumentTypeMismatchException.class)
    public ResponseEntity<ApiError> handleTypeMismatch(MethodArgumentTypeMismatchException ex, HttpServletRequest request) {
        return build(request, 400, "Invalid value '" + ex.getValue() + "' for parameter '" + ex.getName() + "'");
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<ApiError> handleOther(Exception ex, HttpServletRequest request) {
        // Exceptions Spring portant déjà un statut (404 route inconnue, 405 méthode non supportée...)
        if (ex instanceof ErrorResponse errorResponse) {
            return build(request, errorResponse.getStatusCode().value(), ex.getMessage());
        }
        return build(request, 500, "Internal server error - " + ex.getClass().getSimpleName() + ": " + ex.getMessage());
    }

    private ResponseEntity<ApiError> build(HttpServletRequest request, int status, String message) {
        String timestamp = Instant.now().toString();
        request.setAttribute(LoggingInterceptor.ERROR_MESSAGE, message);
        request.setAttribute(LoggingInterceptor.ERROR_TIMESTAMP, timestamp);
        return ResponseEntity.status(status).body(new ApiError(status, message, timestamp));
    }
}
