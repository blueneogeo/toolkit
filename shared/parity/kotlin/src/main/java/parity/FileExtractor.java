package parity;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;
import org.jetbrains.kotlin.com.intellij.psi.PsiElement;
import org.jetbrains.kotlin.com.intellij.psi.util.PsiTreeUtil;
import org.jetbrains.kotlin.lexer.KtTokens;
import org.jetbrains.kotlin.psi.KtAnnotated;
import org.jetbrains.kotlin.psi.KtAnnotationEntry;
import org.jetbrains.kotlin.psi.KtCallExpression;
import org.jetbrains.kotlin.psi.KtClass;
import org.jetbrains.kotlin.psi.KtClassOrObject;
import org.jetbrains.kotlin.psi.KtDeclaration;
import org.jetbrains.kotlin.psi.KtEnumEntry;
import org.jetbrains.kotlin.psi.KtFile;
import org.jetbrains.kotlin.psi.KtImportDirective;
import org.jetbrains.kotlin.psi.KtModifierListOwner;
import org.jetbrains.kotlin.psi.KtNamedFunction;
import org.jetbrains.kotlin.psi.KtObjectDeclaration;
import org.jetbrains.kotlin.psi.KtParameter;
import org.jetbrains.kotlin.psi.KtProperty;
import org.jetbrains.kotlin.psi.KtSecondaryConstructor;
import org.jetbrains.kotlin.psi.KtStringTemplateExpression;
import org.jetbrains.kotlin.psi.KtSuperTypeListEntry;
import org.jetbrains.kotlin.psi.KtTypeAlias;
import org.jetbrains.kotlin.psi.KtTypeReference;
import org.jetbrains.kotlin.psi.KtValueArgument;

final class FileExtractor {
    private static final String STUB_MARKER = "TODO(\"port:";

    private final String path;
    private final KtFile file;
    private final String text;
    private final int[] lineStarts;

    private final List<Object> types = new ArrayList<>();
    private final List<Object> functions = new ArrayList<>();
    private final List<Object> properties = new ArrayList<>();
    private final List<Object> views = new ArrayList<>();
    private final List<Object> debugScripts = new ArrayList<>();
    private final List<Object> tests = new ArrayList<>();

    FileExtractor(String path, KtFile file) {
        this.path = path;
        this.file = file;
        this.text = file.getText();
        List<Integer> starts = new ArrayList<>();
        starts.add(0);
        for (int i = 0; i < text.length(); i++) {
            if (text.charAt(i) == '\n') {
                starts.add(i + 1);
            }
        }
        lineStarts = starts.stream().mapToInt(Integer::intValue).toArray();
    }

    Map<String, Object> extract() {
        List<Object> imports = new ArrayList<>();
        for (KtImportDirective directive : file.getImportDirectives()) {
            if (directive.getImportedFqName() != null) {
                imports.add(directive.getImportedFqName().asString());
            }
        }
        for (KtDeclaration declaration : file.getDeclarations()) {
            if (declaration instanceof KtClassOrObject type) {
                types.add(typeInfo(type, null));
            } else if (declaration instanceof KtTypeAlias alias) {
                types.add(aliasInfo(alias, null));
            } else if (declaration instanceof KtNamedFunction function) {
                Map<String, Object> info = functionInfo(function, false);
                functions.add(info);
                noteView(info);
            } else if (declaration instanceof KtProperty property) {
                properties.add(propertyInfo(property, false));
            }
        }
        Map<String, Object> result = new HashMap<>();
        result.put("path", path);
        result.put("package", file.getPackageFqName().asString());
        result.put("imports", imports);
        result.put("types", types);
        result.put("functions", functions);
        result.put("properties", properties);
        result.put("views", views);
        result.put("accessibility_ids", testTags());
        result.put("debug_scripts", debugScripts);
        result.put("tests", tests);
        result.put("stubs", countOccurrences(STUB_MARKER));
        return result;
    }

    private Map<String, Object> typeInfo(KtClassOrObject type, String parent) {
        String name = type.getName() == null ? "Companion" : type.getName();
        String qualified = parent == null ? name : parent + "." + name;
        Map<String, Object> info = new HashMap<>();
        info.put("name", name);
        info.put("qualified", qualified);
        info.put("kind", typeKind(type));
        info.put("modifiers", modifierNames(type));
        info.put("access", access(type));
        info.put("annotations", annotations(type));
        info.put("conformances", supertypes(type));
        info.put("line", line(type));
        info.put("hash", Fingerprint.of(type.getText()));
        if (parent != null) {
            info.put("parent", parent);
        }

        List<Object> typeProperties = new ArrayList<>();
        List<Object> typeFunctions = new ArrayList<>();
        List<Object> cases = new ArrayList<>();
        List<Object> nested = new ArrayList<>();
        List<String> resetAssigns = new ArrayList<>();

        if (type instanceof KtClass klass && klass.getPrimaryConstructor() != null) {
            for (KtParameter parameter : klass.getPrimaryConstructorParameters()) {
                if (parameter.hasValOrVar()) {
                    typeProperties.add(parameterProperty(parameter));
                }
            }
            typeFunctions.add(constructorInfo(klass.getPrimaryConstructorParameters(), klass.getPrimaryConstructor()));
        }
        for (KtDeclaration declaration : type.getDeclarations()) {
            if (declaration instanceof KtEnumEntry entry) {
                Map<String, Object> entryInfo = new HashMap<>();
                entryInfo.put("name", entry.getName());
                entryInfo.put("line", line(entry));
                cases.add(entryInfo);
            } else if (declaration instanceof KtObjectDeclaration object && object.isCompanion()) {
                for (KtDeclaration member : object.getDeclarations()) {
                    if (member instanceof KtNamedFunction function) {
                        Map<String, Object> functionInfo = functionInfo(function, true);
                        if ("invoke".equals(function.getName()) && function.hasModifier(KtTokens.OPERATOR_KEYWORD)) {
                            functionInfo.put("name", "init");
                            functionInfo.put("key", "init/" + function.getValueParameters().size());
                        }
                        typeFunctions.add(functionInfo);
                    } else if (member instanceof KtProperty property) {
                        typeProperties.add(propertyInfo(property, true));
                    } else if (member instanceof KtClassOrObject inner) {
                        nested.add(typeInfo(inner, qualified));
                    }
                }
            } else if (declaration instanceof KtClassOrObject inner) {
                nested.add(typeInfo(inner, qualified));
            } else if (declaration instanceof KtTypeAlias alias) {
                nested.add(aliasInfo(alias, qualified));
            } else if (declaration instanceof KtNamedFunction function) {
                Map<String, Object> functionInfo = functionInfo(function, false);
                typeFunctions.add(functionInfo);
                if ("reset".equals(function.getName()) && function.getValueParameters().isEmpty()) {
                    resetAssigns.addAll(assignedNames(function));
                }
            } else if (declaration instanceof KtSecondaryConstructor constructor) {
                typeFunctions.add(constructorInfo(constructor.getValueParameters(), constructor));
            } else if (declaration instanceof KtProperty property) {
                typeProperties.add(propertyInfo(property, false));
            }
        }
        info.put("properties", typeProperties);
        info.put("functions", typeFunctions);
        info.put("cases", cases);
        info.put("types", nested);
        info.put("reset_assigns", resetAssigns);

        List<String> conformances = supertypes(type);
        if (conformances.contains("DebugScript")) {
            String scriptName = stringProperty(type, "name");
            if (scriptName != null) {
                Map<String, Object> script = new HashMap<>();
                script.put("name", scriptName);
                script.put("type", name);
                script.put("line", line(type));
                debugScripts.add(script);
            }
        }
        List<Object> testMethods = new ArrayList<>();
        for (Object function : typeFunctions) {
            @SuppressWarnings("unchecked")
            Map<String, Object> functionInfo = (Map<String, Object>) function;
            @SuppressWarnings("unchecked")
            List<String> functionAnnotations = (List<String>) functionInfo.get("annotations");
            if (functionAnnotations != null && functionAnnotations.contains("Test")) {
                testMethods.add(functionInfo.get("name"));
            }
        }
        if (!testMethods.isEmpty()) {
            Map<String, Object> test = new HashMap<>();
            test.put("class", name);
            test.put("methods", testMethods);
            tests.add(test);
        }
        if (parent == null && conformances.contains("Shape") && !"private".equals(access(type))) {
            Map<String, Object> view = new HashMap<>();
            view.put("name", name);
            view.put("kind", "Shape");
            view.put("access", access(type));
            view.put("line", line(type));
            views.add(view);
        }
        return info;
    }

    private Map<String, Object> aliasInfo(KtTypeAlias alias, String parent) {
        Map<String, Object> info = new HashMap<>();
        info.put("name", alias.getName());
        info.put("qualified", parent == null ? alias.getName() : parent + "." + alias.getName());
        info.put("kind", "typealias");
        info.put("access", access(alias));
        info.put("line", line(alias));
        info.put("properties", List.of());
        info.put("functions", List.of());
        info.put("cases", List.of());
        info.put("types", List.of());
        return info;
    }

    private Map<String, Object> functionInfo(KtNamedFunction function, boolean isStatic) {
        Map<String, Object> info = new HashMap<>();
        String name = function.getName();
        List<Object> params = new ArrayList<>();
        for (KtParameter parameter : function.getValueParameters()) {
            params.add(parameter.getName());
        }
        info.put("name", name);
        info.put("key", name + "/" + params.size());
        info.put("params", params);
        info.put("receiver", receiver(function.getReceiverTypeReference()));
        info.put("access", access(function));
        info.put("static", isStatic);
        info.put("suspend", function.hasModifier(KtTokens.SUSPEND_KEYWORD));
        info.put("annotations", annotations(function));
        info.put("line", line(function));
        info.put("stub", function.getText().contains(STUB_MARKER));
        info.put("hash", Fingerprint.of(function.getText()));
        return info;
    }

    private Map<String, Object> constructorInfo(List<KtParameter> parameters, PsiElement element) {
        Map<String, Object> info = new HashMap<>();
        List<Object> params = new ArrayList<>();
        for (KtParameter parameter : parameters) {
            params.add(parameter.getName());
        }
        info.put("name", "init");
        info.put("key", "init/" + params.size());
        info.put("params", params);
        info.put("receiver", "");
        info.put("access", "public");
        info.put("static", false);
        info.put("annotations", List.of());
        info.put("line", line(element));
        info.put("stub", element.getText().contains(STUB_MARKER));
        return info;
    }

    private Map<String, Object> propertyInfo(KtProperty property, boolean isStatic) {
        Map<String, Object> info = new HashMap<>();
        info.put("name", property.getName());
        info.put("mutable", property.isVar());
        info.put("receiver", receiver(property.getReceiverTypeReference()));
        info.put("access", access(property));
        info.put("static", isStatic);
        info.put("delegate", property.getDelegateExpression() == null ? "" : property.getDelegateExpression().getText().split("[(<{]", 2)[0]);
        info.put("computed", property.getGetter() != null && property.getGetter().hasBody());
        info.put("annotations", annotations(property));
        info.put("line", line(property));
        info.put("stub", property.getText().contains(STUB_MARKER));
        info.put("hash", Fingerprint.of(property.getText()));
        return info;
    }

    private Map<String, Object> parameterProperty(KtParameter parameter) {
        Map<String, Object> info = new HashMap<>();
        info.put("name", parameter.getName());
        info.put("mutable", parameter.isMutable());
        info.put("receiver", "");
        info.put("access", access(parameter));
        info.put("static", false);
        info.put("delegate", "");
        info.put("computed", false);
        info.put("annotations", annotations(parameter));
        info.put("line", line(parameter));
        info.put("stub", false);
        return info;
    }

    private void noteView(Map<String, Object> function) {
        String name = (String) function.get("name");
        String receiver = (String) function.get("receiver");
        @SuppressWarnings("unchecked")
        List<String> functionAnnotations = (List<String>) function.get("annotations");
        String kind = null;
        if ("Modifier".equals(receiver)) {
            kind = "ModifierExtension";
        } else if (functionAnnotations.contains("Composable") && name != null && !name.isEmpty()) {
            kind = Character.isUpperCase(name.charAt(0)) ? "Composable" : "ComposableFunction";
        }
        if (kind == null) {
            return;
        }
        Map<String, Object> view = new HashMap<>();
        view.put("name", name);
        view.put("kind", kind);
        view.put("access", function.get("access"));
        view.put("line", function.get("line"));
        view.put("key", function.get("key"));
        view.put("stub", function.get("stub"));
        views.add(view);
    }

    private List<Object> testTags() {
        TreeSet<String> tags = new TreeSet<>();
        for (KtCallExpression call : PsiTreeUtil.collectElementsOfType(file, KtCallExpression.class)) {
            if (call.getCalleeExpression() == null || !"testTag".equals(call.getCalleeExpression().getText())) {
                continue;
            }
            List<KtValueArgument> arguments = call.getValueArguments();
            if (!arguments.isEmpty() && arguments.get(0).getArgumentExpression() instanceof KtStringTemplateExpression literal
                && !literal.hasInterpolation()) {
                String raw = literal.getText();
                tags.add(raw.substring(1, raw.length() - 1));
            }
        }
        return new ArrayList<>(tags);
    }

    private String stringProperty(KtClassOrObject type, String propertyName) {
        for (KtDeclaration declaration : type.getDeclarations()) {
            if (declaration instanceof KtProperty property && propertyName.equals(property.getName())
                && property.getInitializer() instanceof KtStringTemplateExpression literal && !literal.hasInterpolation()) {
                String raw = literal.getText();
                return raw.substring(1, raw.length() - 1);
            }
        }
        return null;
    }

    private List<String> assignedNames(KtNamedFunction function) {
        List<String> names = new ArrayList<>();
        for (org.jetbrains.kotlin.psi.KtBinaryExpression binary
            : PsiTreeUtil.collectElementsOfType(function, org.jetbrains.kotlin.psi.KtBinaryExpression.class)) {
            if (binary.getOperationToken() != KtTokens.EQ || binary.getLeft() == null) {
                continue;
            }
            String left = binary.getLeft().getText();
            if (left.startsWith("this.")) {
                left = left.substring(5);
            }
            if (left.matches("[A-Za-z_][A-Za-z0-9_]*")) {
                names.add(left);
            }
        }
        return names;
    }

    private static String typeKind(KtClassOrObject type) {
        if (type instanceof KtObjectDeclaration object) {
            return object.isCompanion() ? "companion" : "object";
        }
        KtClass klass = (KtClass) type;
        if (klass.isInterface()) {
            return "interface";
        }
        if (klass.isEnum()) {
            return "enum";
        }
        if (klass.isAnnotation()) {
            return "annotation";
        }
        return "class";
    }

    private static List<String> modifierNames(KtModifierListOwner owner) {
        List<String> names = new ArrayList<>();
        for (var token : List.of(KtTokens.DATA_KEYWORD, KtTokens.SEALED_KEYWORD, KtTokens.ABSTRACT_KEYWORD, KtTokens.OPEN_KEYWORD,
            KtTokens.VALUE_KEYWORD, KtTokens.INNER_KEYWORD)) {
            if (owner.hasModifier(token)) {
                names.add(token.getValue());
            }
        }
        return names;
    }

    private static String access(KtModifierListOwner owner) {
        if (owner.hasModifier(KtTokens.PRIVATE_KEYWORD)) {
            return "private";
        }
        if (owner.hasModifier(KtTokens.PROTECTED_KEYWORD)) {
            return "protected";
        }
        if (owner.hasModifier(KtTokens.INTERNAL_KEYWORD)) {
            return "internal";
        }
        return "public";
    }

    private static List<String> annotations(KtAnnotated annotated) {
        List<String> names = new ArrayList<>();
        for (KtAnnotationEntry entry : annotated.getAnnotationEntries()) {
            if (entry.getShortName() != null) {
                names.add(entry.getShortName().asString());
            }
        }
        return names;
    }

    private static List<String> supertypes(KtClassOrObject type) {
        List<String> names = new ArrayList<>();
        for (KtSuperTypeListEntry entry : type.getSuperTypeListEntries()) {
            if (entry.getTypeReference() != null) {
                names.add(simpleTypeName(entry.getTypeReference().getText()));
            }
        }
        return names;
    }

    private static String receiver(KtTypeReference reference) {
        return reference == null ? "" : simpleTypeName(reference.getText());
    }

    private static String simpleTypeName(String raw) {
        String name = raw.replaceAll("<.*>", "").replace("?", "").trim();
        int space = name.lastIndexOf(' ');
        return space >= 0 ? name.substring(space + 1) : name;
    }

    private int line(PsiElement element) {
        int offset = element.getTextOffset();
        int low = 0;
        int high = lineStarts.length - 1;
        while (low < high) {
            int mid = (low + high + 1) >>> 1;
            if (lineStarts[mid] <= offset) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        return low + 1;
    }

    private int countOccurrences(String needle) {
        int count = 0;
        int index = text.indexOf(needle);
        while (index >= 0) {
            count++;
            index = text.indexOf(needle, index + needle.length());
        }
        return count;
    }
}
