@IsTest
private class JsonPathTest {
    private static final Object DOC = JSON.deserializeUntyped('{"id":"evt_1","data":{"object":{"id":"cus_9","amount":1250,"paid":true}},"items":[{"sku":"A"},{"sku":"B"}]}');

    @IsTest
    static void walksMapsAndLists() {
        Assert.areEqual('evt_1', JsonPath.getString(DOC, 'id'), 'top level');
        Assert.areEqual('cus_9', JsonPath.getString(DOC, 'data.object.id'), 'nested');
        Assert.areEqual('B', JsonPath.getString(DOC, 'items.1.sku'), 'list index');
        Assert.areEqual('1250', JsonPath.getString(DOC, 'data.object.amount'), 'numbers rendered as text');
        Assert.areEqual('true', JsonPath.getString(DOC, 'data.object.paid'), 'booleans rendered as text');
        Assert.isTrue(JsonPath.get(DOC, 'data.object') instanceof Map<String, Object>, 'objects returned as maps');
    }

    @IsTest
    static void missingPathsAreNull() {
        Assert.isNull(JsonPath.get(DOC, 'nope'), 'missing key');
        Assert.isNull(JsonPath.get(DOC, 'data.nope.id'), 'missing middle');
        Assert.isNull(JsonPath.get(DOC, 'items.5.sku'), 'index out of range');
        Assert.isNull(JsonPath.get(DOC, 'items.x'), 'non-numeric index');
        Assert.isNull(JsonPath.get(DOC, 'id.more'), 'path into a scalar');
        Assert.isNull(JsonPath.get(DOC, ''), 'blank path');
        Assert.isNull(JsonPath.get(null, 'id'), 'null root');
        Assert.isNull(JsonPath.getString(DOC, 'nope'), 'string form');
    }
}
