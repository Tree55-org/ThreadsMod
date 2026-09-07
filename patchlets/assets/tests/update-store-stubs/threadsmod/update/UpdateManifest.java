package threadsmod.update;

/** Host-only minimal manifest model used to execute the production UpdateStore. */
final class UpdateManifest {
    final long revision;
    final long modBuild;
    final long minimumModBuild;
    final long versionCode;
    final String envelope;
    private final String signedRelease;
    private final String binaryIdentity;

    UpdateManifest(
            long revision, long modBuild, long minimumModBuild, long versionCode,
            String signedRelease, String binaryIdentity) {
        this.revision = revision;
        this.modBuild = modBuild;
        this.minimumModBuild = minimumModBuild;
        this.versionCode = versionCode;
        this.signedRelease = signedRelease;
        this.binaryIdentity = binaryIdentity;
        this.envelope = revision + "|" + modBuild + "|" + minimumModBuild + "|"
                + versionCode + "|"
                + signedRelease + "|" + binaryIdentity;
    }

    static UpdateManifest parseStored(String envelope) {
        String[] fields = envelope.split("\\|", -1);
        if (fields.length != 6) throw new IllegalArgumentException("invalid fixture envelope");
        return new UpdateManifest(
                Long.parseLong(fields[0]), Long.parseLong(fields[1]),
                Long.parseLong(fields[2]), Long.parseLong(fields[3]), fields[4], fields[5]);
    }

    boolean sameSignedRelease(UpdateManifest other) {
        return other != null && revision == other.revision
                && signedRelease.equals(other.signedRelease);
    }

    boolean sameBinary(UpdateManifest other) {
        return other != null && modBuild == other.modBuild
                && versionCode == other.versionCode
                && binaryIdentity.equals(other.binaryIdentity);
    }
}
