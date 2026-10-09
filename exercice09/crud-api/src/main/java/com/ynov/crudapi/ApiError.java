package com.ynov.crudapi;

public record ApiError(int status, String error, String timestamp) {
}
