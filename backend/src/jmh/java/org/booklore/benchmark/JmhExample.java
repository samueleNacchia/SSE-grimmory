package org.booklore.benchmark;

import org.openjdk.jmh.annotations.*;

@State(Scope.Thread)
@BenchmarkMode(Mode.AverageTime)
public class JmhExample {

    @Setup(Level.Trial)
    public void setup() {
        // Preparazione dei dati utili per il benchmark
        System.out.println("setting up the benchmark");
    }

    @Benchmark
    public void benchmarkMapping() {
        // Invocazione del metodo per benchmark
        System.out.println("runnning the benchmark");
    }
}

/* ToDo: /api/v1/books */
