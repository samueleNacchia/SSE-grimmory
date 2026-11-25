package org.booklore.benchmark;

import org.openjdk.jmh.annotations.*;
import java.util.concurrent.TimeUnit;

@State(Scope.Thread)
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.MICROSECONDS)
public class JmhExample {
    @Setup(Level.Trial)
    public void setup() {
        // Preparazione dei dati utili per il benchmark
    }

    @Benchmark
    public void benchmarkMapping() {
        // Invocazione del metodo per benchmark
    }
}

