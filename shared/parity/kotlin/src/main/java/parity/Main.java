package parity;

import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.jetbrains.kotlin.cli.FrontendConfigurationKeysKt;
import org.jetbrains.kotlin.cli.common.CLIConfigurationKeys;
import org.jetbrains.kotlin.cli.common.messages.MessageCollector;
import org.jetbrains.kotlin.cli.jvm.compiler.EnvironmentConfigFiles;
import org.jetbrains.kotlin.cli.jvm.compiler.KotlinCoreEnvironment;
import org.jetbrains.kotlin.com.intellij.openapi.Disposable;
import org.jetbrains.kotlin.com.intellij.openapi.util.Disposer;
import org.jetbrains.kotlin.compiler.plugin.CompilerPluginRegistrar;
import org.jetbrains.kotlin.config.CommonConfigurationKeys;
import org.jetbrains.kotlin.config.CompilerConfiguration;
import org.jetbrains.kotlin.psi.KtPsiFactory;

/** Usage: parity-kotlin <list-file>. Each line is "<file on disk>\t<path to report>". */
public final class Main {
    private Main() {}

    public static void main(String[] args) throws IOException {
        if (args.length != 1) {
            System.err.println("usage: parity-kotlin <list-file>");
            System.exit(2);
        }
        Disposable disposable = Disposer.newDisposable();
        CompilerConfiguration configuration = new CompilerConfiguration();
        configuration.put(CLIConfigurationKeys.MESSAGE_COLLECTOR_KEY, MessageCollector.Companion.getNONE());
        configuration.put(CommonConfigurationKeys.MODULE_NAME, "parity");
        FrontendConfigurationKeysKt.setExtensionsStorage(configuration, new CompilerPluginRegistrar.ExtensionStorage());
        KotlinCoreEnvironment environment = KotlinCoreEnvironment.createForProduction(
            disposable, configuration, EnvironmentConfigFiles.JVM_CONFIG_FILES);
        KtPsiFactory factory = new KtPsiFactory(environment.getProject(), false);

        List<Object> files = new ArrayList<>();
        for (String line : Files.readAllLines(Path.of(args[0]), StandardCharsets.UTF_8)) {
            String[] parts = line.split("\t", 2);
            if (parts.length != 2) {
                continue;
            }
            String source = Files.readString(Path.of(parts[0]), StandardCharsets.UTF_8);
            files.add(new FileExtractor(parts[1], factory.createFile(Path.of(parts[1]).getFileName().toString(), source)).extract());
        }
        PrintStream out = new PrintStream(System.out, false, StandardCharsets.UTF_8);
        out.println(Json.write(Map.of("schema", 1, "platform", "android", "files", files)));
        out.flush();
        Disposer.dispose(disposable);
    }
}
