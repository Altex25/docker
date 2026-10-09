package com.ynov.crudapi;

import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import java.net.URI;
import java.util.List;

@RestController
@RequestMapping("/api/v1/dogs")
public class DogController {

    private final DogRepository repository;

    public DogController(DogRepository repository) {
        this.repository = repository;
    }

    @GetMapping
    public List<Dog> findAll() {
        return repository.findAll();
    }

    @GetMapping("/{dogId}")
    public Dog findById(@PathVariable Long dogId) {
        return repository.findById(dogId).orElseThrow(() -> new DogNotFoundException(dogId));
    }

    @PostMapping
    public ResponseEntity<Dog> create(@Valid @RequestBody Dog dog) {
        dog.setId(null);
        Dog saved = repository.save(dog);
        return ResponseEntity.created(URI.create("/api/v1/dogs/" + saved.getId())).body(saved);
    }

    @PutMapping("/{dogId}")
    public Dog update(@PathVariable Long dogId, @Valid @RequestBody Dog input) {
        Dog dog = repository.findById(dogId).orElseThrow(() -> new DogNotFoundException(dogId));
        dog.setName(input.getName());
        dog.setBirthDate(input.getBirthDate());
        dog.setBreed(input.getBreed());
        dog.setSterilized(input.isSterilized());
        return repository.save(dog);
    }

    @DeleteMapping("/{dogId}")
    public ResponseEntity<Void> delete(@PathVariable Long dogId) {
        if (!repository.existsById(dogId)) {
            throw new DogNotFoundException(dogId);
        }
        repository.deleteById(dogId);
        return ResponseEntity.noContent().build();
    }
}
