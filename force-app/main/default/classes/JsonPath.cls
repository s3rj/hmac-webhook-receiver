/**
 * Dot-path lookups over JSON parsed with JSON.deserializeUntyped(): "id", "data.object.id", "items.0.sku".
 */
public with sharing class JsonPath {
    /** The value at the path, or null when any segment is missing. */
    public static Object get(Object root, String path) {
        if (root == null || String.isBlank(path)) {
            return null;
        }
        Object current = root;
        for (String segment : path.split('\\.')) {
            if (current instanceof Map<String, Object>) {
                current = ((Map<String, Object>) current).get(segment);
            } else if (current instanceof List<Object> && segment.isNumeric()) {
                List<Object> items = (List<Object>) current;
                Integer index = Integer.valueOf(segment);
                current = index < items.size() ? items[index] : null;
            } else {
                return null;
            }
            if (current == null) {
                return null;
            }
        }
        return current;
    }

    /** The value at the path as text (numbers and booleans are rendered), or null. */
    public static String getString(Object root, String path) {
        Object value = get(root, path);
        if (value == null) {
            return null;
        }
        return value instanceof String ? (String) value : String.valueOf(value);
    }
}
