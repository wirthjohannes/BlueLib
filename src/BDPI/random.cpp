#include <tr1/random>
#include <functional> //for std::hash
#include <string>
#include <iostream>

class RandomGen {
public:
    RandomGen(uint32_t seed): rand(seed) {}

    uint64_t next() {
        return rand();
    }
private:
    std::tr1::mt19937 rand;
};

extern "C" {
    uint64_t random_init_seed(const char* name, uint32_t seed) {
        std::cout << "Using seed " << seed << std::endl;
        std::string string = name;
        std::hash<std::string> hasher;
        auto hashed = hasher(name);

        auto gen = new RandomGen(hashed ^ seed);
        return (uint64_t) gen;
    }

    uint64_t random_init(const char* name) {
        return random_init_seed(name, time(NULL));
    }

    uint32_t random_next(uint64_t ptr) {
        RandomGen *gen = (RandomGen*) ptr;
        return gen->next();
    }

    void random_destroy(uint64_t ptr) {
        RandomGen *gen = (RandomGen*) ptr;
        delete (gen);
    }
}