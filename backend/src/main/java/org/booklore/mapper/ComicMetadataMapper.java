package org.booklore.mapper;

import org.booklore.model.dto.ComicMetadata;
import org.booklore.model.entity.*;
import org.booklore.model.enums.ComicCreatorRole;
import org.mapstruct.AfterMapping;
import org.mapstruct.BeanMapping;
import org.mapstruct.Mapper;
import org.mapstruct.Mapping;
import org.mapstruct.MappingTarget;
import org.mapstruct.Named;
import org.mapstruct.ReportingPolicy;

import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

@Mapper(componentModel = "spring", unmappedTargetPolicy = ReportingPolicy.IGNORE)
public interface ComicMetadataMapper {

    @Mapping(target = "characters", source = "characters", qualifiedByName = "charactersToStrings")
    @Mapping(target = "teams", source = "teams", qualifiedByName = "teamsToStrings")
    @Mapping(target = "locations", source = "locations", qualifiedByName = "locationsToStrings")
    @Mapping(target = "pencillers", ignore = true)
    @Mapping(target = "inkers", ignore = true)
    @Mapping(target = "colorists", ignore = true)
    @Mapping(target = "letterers", ignore = true)
    @Mapping(target = "coverArtists", ignore = true)
    @Mapping(target = "editors", ignore = true)
    ComicMetadata toComicMetadata(ComicMetadataEntity entity);

    @Named("toListViewComicMetadata")
    @BeanMapping(ignoreByDefault = true)
    @Mapping(target = "characters", source = "characters", qualifiedByName = "charactersToStrings")
    @Mapping(target = "teams", source = "teams", qualifiedByName = "teamsToStrings")
    @Mapping(target = "locations", source = "locations", qualifiedByName = "locationsToStrings")
    ComicMetadata toListViewComicMetadata(ComicMetadataEntity entity);

    @Named("charactersToStrings")
    default Set<String> charactersToStrings(Set<ComicCharacterEntity> characters) {
        if (characters == null || characters.isEmpty()) return Collections.emptySet();
        Set<String> result = HashSet.newHashSet(characters.size());
        for (ComicCharacterEntity c : characters) {
            result.add(c.getName());
        }
        return result;
    }

    @Named("teamsToStrings")
    default Set<String> teamsToStrings(Set<ComicTeamEntity> teams) {
        if (teams == null || teams.isEmpty()) return Collections.emptySet();
        Set<String> result = HashSet.newHashSet(teams.size());
        for (ComicTeamEntity t : teams) {
            result.add(t.getName());
        }
        return result;
    }

    @Named("locationsToStrings")
    default Set<String> locationsToStrings(Set<ComicLocationEntity> locations) {
        if (locations == null || locations.isEmpty()) return Collections.emptySet();
        Set<String> result = HashSet.newHashSet(locations.size());
        for (ComicLocationEntity l : locations) {
            result.add(l.getName());
        }
        return result;
    }

    @Named("pencillersToStrings")
    default Set<String> pencillersToStrings(Set<ComicCreatorMappingEntity> mappings) {
        return creatorsToStringsByRole(mappings, ComicCreatorRole.PENCILLER);
    }

    @Named("inkersToStrings")
    default Set<String> inkersToStrings(Set<ComicCreatorMappingEntity> mappings) {
        return creatorsToStringsByRole(mappings, ComicCreatorRole.INKER);
    }

    @Named("coloristsToStrings")
    default Set<String> coloristsToStrings(Set<ComicCreatorMappingEntity> mappings) {
        return creatorsToStringsByRole(mappings, ComicCreatorRole.COLORIST);
    }

    @Named("letterersToStrings")
    default Set<String> letterersToStrings(Set<ComicCreatorMappingEntity> mappings) {
        return creatorsToStringsByRole(mappings, ComicCreatorRole.LETTERER);
    }

    @Named("coverArtistsToStrings")
    default Set<String> coverArtistsToStrings(Set<ComicCreatorMappingEntity> mappings) {
        return creatorsToStringsByRole(mappings, ComicCreatorRole.COVER_ARTIST);
    }

    @Named("editorsToStrings")
    default Set<String> editorsToStrings(Set<ComicCreatorMappingEntity> mappings) {
        return creatorsToStringsByRole(mappings, ComicCreatorRole.EDITOR);
    }

    default Set<String> creatorsToStringsByRole(Set<ComicCreatorMappingEntity> mappings, ComicCreatorRole role) {
        if (mappings == null || mappings.isEmpty()) return Collections.emptySet();
        Set<String> result = null;
        for (ComicCreatorMappingEntity m : mappings) {
            if (m.getRole() == role && m.getCreator() != null) {
                if (result == null) result = new HashSet<>();
                result.add(m.getCreator().getName());
            }
        }
        return result != null ? result : Collections.emptySet();
    }

    @AfterMapping
    default void mapCreatorsSinglePass(ComicMetadataEntity entity, @MappingTarget ComicMetadata target) {
        if (entity == null) return;
        Set<ComicCreatorMappingEntity> mappings = entity.getCreatorMappings();
        if (mappings == null || mappings.isEmpty()) {
            target.setPencillers(Collections.emptySet());
            target.setInkers(Collections.emptySet());
            target.setColorists(Collections.emptySet());
            target.setLetterers(Collections.emptySet());
            target.setCoverArtists(Collections.emptySet());
            target.setEditors(Collections.emptySet());
            return;
        }
        Set<String> pencillers = null;
        Set<String> inkers = null;
        Set<String> colorists = null;
        Set<String> letterers = null;
        Set<String> coverArtists = null;
        Set<String> editors = null;

        for (ComicCreatorMappingEntity m : mappings) {
            if (m.getRole() == null || m.getCreator() == null) continue;
            String name = m.getCreator().getName();
            switch (m.getRole()) {
                case PENCILLER -> {
                    if (pencillers == null) pencillers = new HashSet<>();
                    pencillers.add(name);
                }
                case INKER -> {
                    if (inkers == null) inkers = new HashSet<>();
                    inkers.add(name);
                }
                case COLORIST -> {
                    if (colorists == null) colorists = new HashSet<>();
                    colorists.add(name);
                }
                case LETTERER -> {
                    if (letterers == null) letterers = new HashSet<>();
                    letterers.add(name);
                }
                case COVER_ARTIST -> {
                    if (coverArtists == null) coverArtists = new HashSet<>();
                    coverArtists.add(name);
                }
                case EDITOR -> {
                    if (editors == null) editors = new HashSet<>();
                    editors.add(name);
                }
            }
        }
        target.setPencillers(pencillers != null ? pencillers : Collections.emptySet());
        target.setInkers(inkers != null ? inkers : Collections.emptySet());
        target.setColorists(colorists != null ? colorists : Collections.emptySet());
        target.setLetterers(letterers != null ? letterers : Collections.emptySet());
        target.setCoverArtists(coverArtists != null ? coverArtists : Collections.emptySet());
        target.setEditors(editors != null ? editors : Collections.emptySet());
    }
}