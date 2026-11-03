import Testing
@testable import Susurrus

/// What dropping on a sidebar playlist row does, which is also what lights the row up.
struct SidebarDropTests {
    @Test func tracksGoIntoRegularPlaylistsOnly() {
        #expect(PlaylistDrop.of(kind: .regular, hasFiles: true, hasPlaylist: false) == .addTracks)
        #expect(PlaylistDrop.of(kind: .smart, hasFiles: true, hasPlaylist: false) == nil, "its rules decide what's in it")
        #expect(PlaylistDrop.of(kind: .folder, hasFiles: true, hasPlaylist: false) == nil)
    }

    @Test func aDraggedPlaylistCanLandAnywhere() {
        for kind in [Playlist.Kind.regular, .smart, .folder] {
            #expect(PlaylistDrop.of(kind: kind, hasFiles: false, hasPlaylist: true) == .movePlaylist)
        }
        #expect(PlaylistDrop.of(kind: .folder, hasFiles: true, hasPlaylist: true) == .movePlaylist, "the playlist is what the drag is about")
    }

    @Test func nothingToTakeLightsNothingUp() {
        #expect(PlaylistDrop.of(kind: .regular, hasFiles: false, hasPlaylist: false) == nil)
    }
}
