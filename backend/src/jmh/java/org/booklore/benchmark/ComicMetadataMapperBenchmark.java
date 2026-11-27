package org.booklore.benchmark;

import org.booklore.mapper.ComicMetadataMapper;
import org.booklore.model.dto.ComicMetadata;
import org.booklore.model.entity.*;
import org.booklore.model.enums.ComicCreatorRole;
import org.mapstruct.factory.Mappers;
import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.infra.Blackhole;

import java.util.*;
import java.util.concurrent.TimeUnit;

@State(Scope.Benchmark)
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.MICROSECONDS)
public class ComicMetadataMapperBenchmark {

    private ComicMetadataMapper mapper;
    private List<ComicMetadataEntity> comicEntities;

    @Setup(Level.Trial)
    public void setup() {
        mapper = Mappers.getMapper(ComicMetadataMapper.class);
        comicEntities = new ArrayList<>(1000);

        for (long i = 1; i <= 1000; i++) {
            ComicMetadataEntity entity = new ComicMetadataEntity();
            entity.setBookId(i);
            entity.setIssueNumber(String.valueOf(i));
            entity.setVolumeName("Volume " + (i % 10));
            entity.setStoryArc("Arc " + (i % 5));
            entity.setNotes("Detailed editorial notes for issue " + i);

            ComicCharacterEntity ch1 = new ComicCharacterEntity();
            ch1.setId(i * 10 + 1);
            ch1.setName("Hero " + (i % 20));
            entity.setCharacters(Set.of(ch1));

            ComicTeamEntity team1 = new ComicTeamEntity();
            team1.setId(i * 10 + 1);
            team1.setName("Team Alpha");
            entity.setTeams(Set.of(team1));

            ComicLocationEntity loc1 = new ComicLocationEntity();
            loc1.setId(i * 10 + 1);
            loc1.setName("Metropolis");
            entity.setLocations(Set.of(loc1));

            Set<ComicCreatorMappingEntity> mappings = new LinkedHashSet<>();
            ComicCreatorRole[] roles = {
                    ComicCreatorRole.PENCILLER,
                    ComicCreatorRole.INKER,
                    ComicCreatorRole.COLORIST,
                    ComicCreatorRole.EDITOR
            };
            for (int r = 0; r < roles.length; r++) {
                ComicCreatorEntity creator = new ComicCreatorEntity();
                creator.setId(i * 10 + r);
                creator.setName("Creator " + r);

                ComicCreatorMappingEntity mapping = new ComicCreatorMappingEntity();
                mapping.setId(i * 10 + r);
                mapping.setRole(roles[r]);
                mapping.setCreator(creator);
                mappings.add(mapping);
            }
            entity.setCreatorMappings(mappings);

            comicEntities.add(entity);
        }
    }

    @Benchmark
    public void mapComicMetadata(Blackhole bh) {
        int size = comicEntities.size();
        List<ComicMetadata> result = new ArrayList<>(size);
        for (int i = 0; i < size; i++) {
            result.add(mapper.toComicMetadata(comicEntities.get(i)));
        }
        bh.consume(result);
    }
}
