import brut.androlib.smali.SmaliBuilder;
import com.android.tools.smali.dexlib2.Opcodes;
import com.android.tools.smali.dexlib2.writer.builder.DexBuilder;
import com.android.tools.smali.dexlib2.writer.io.FileDataStore;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

/** Test-only deterministic Smali-to-DEX assembler for bridge-flow fixtures. */
public final class DexBridgeFlowFixtureAssembler {
    private DexBridgeFlowFixtureAssembler() {}

    public static void main(String[] args) throws Exception {
        if (args.length != 2) {
            throw new IllegalArgumentException("usage: SOURCE_ROOT OUTPUT_DEX");
        }
        Path sourceRoot = new File(args[0]).toPath();
        File output = new File(args[1]);
        if (!Files.isDirectory(sourceRoot) || output.exists()) {
            throw new IllegalArgumentException("fixture paths are outside the expected state");
        }
        List<Path> sources = new ArrayList<>();
        try (java.util.stream.Stream<Path> stream = Files.walk(sourceRoot)) {
            stream.filter(path -> Files.isRegularFile(path)
                    && path.getFileName().toString().endsWith(".smali"))
                    .sorted(Comparator.comparing(Path::toString))
                    .forEach(sources::add);
        }
        if (sources.isEmpty()) throw new IllegalArgumentException("fixture has no Smali sources");

        int api = 28;
        DexBuilder dex = new DexBuilder(new Opcodes(api));
        SmaliBuilder smali = new SmaliBuilder(api);
        for (Path source : sources) {
            if (!smali.buildFile(source.toFile(), dex)) {
                throw new IllegalStateException("fixture Smali assembly failed");
            }
        }
        FileDataStore store = new FileDataStore(output);
        try {
            dex.writeTo(store);
        } finally {
            store.raf.close();
        }
    }
}
