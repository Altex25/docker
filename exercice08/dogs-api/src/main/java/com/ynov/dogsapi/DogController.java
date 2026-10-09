package com.ynov.dogsapi;

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
    public ResponseEntity<Dog> findById(@PathVariable Long dogId) {
        return repository.findById(dogId)
                .map(ResponseEntity::ok)
                .orElse(ResponseEntity.notFound().build());
    }

    @PostMapping
    public ResponseEntity<Dog> create(@Valid @RequestBody Dog dog) {
        dog.setId(null);
        Dog saved = repository.save(dog);
        return ResponseEntity.created(URI.create("/api/v1/dogs/" + saved.getId())).body(saved);
    }

    @PutMapping("/{dogId}")
    public ResponseEntity<Dog> update(@PathVariable Long dogId, @Valid @RequestBody Dog input) {
        return repository.findById(dogId)
                .map(dog -> {
                    dog.setName(input.getName());
                    dog.setBirthDate(input.getBirthDate());
                    dog.setBreed(input.getBreed());
                    dog.setSterilized(input.isSterilized());
                    return ResponseEntity.ok(repository.save(dog));
                })
                .orElse(ResponseEntity.notFound().build());
    }

    @DeleteMapping("/{dogId}")
    public ResponseEntity<Void> delete(@PathVariable Long dogId) {
        if (!repository.existsById(dogId)) {
            return ResponseEntity.notFound().build();
        }
        repository.deleteById(dogId);
        return ResponseEntity.noContent().build();
    }
}
