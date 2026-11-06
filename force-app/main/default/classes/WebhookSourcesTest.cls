@IsTest
private class WebhookSourcesTest {
    @IsTest
    static void shippedSourcesAreFoundCaseInsensitively() {
        WebhookSources.Source github = WebhookSources.find('GITHUB');
        Assert.isNotNull(github, 'GitHub source shipped');
        Assert.areEqual('Github', github.name, 'developer name kept');
        Assert.areEqual('X-Hub-Signature-256', github.signatureHeader, 'signature header');
        Assert.areEqual('sha256=', github.signaturePrefix, 'prefix');
        Assert.areEqual(WebhookSignature.Scheme.BODY, github.scheme, 'body scheme');
        Assert.areEqual('X-GitHub-Delivery', github.eventIdHeader, 'id header');
        Assert.areEqual('X-GitHub-Event', github.eventTypeHeader, 'type header');
        Assert.isNull(github.toleranceSeconds, 'no tolerance for the body scheme');

        WebhookSources.Source demo = WebhookSources.find('demo');
        Assert.areEqual(WebhookSignature.Scheme.TIMESTAMP_DOT_BODY, demo.scheme, 'timestamp scheme');
        Assert.areEqual('X-Timestamp', demo.timestampHeader, 'timestamp header');
        Assert.areEqual(300, demo.toleranceSeconds, 'tolerance');
        Assert.areEqual('id', demo.eventIdPath, 'id path');
        Assert.areEqual('type', demo.eventTypePath, 'type path');
        Assert.areEqual(new List<String>{ 'X-Signature', 'X-Timestamp' }, demo.interestingHeaders(), 'headers worth keeping');

        Assert.isNull(WebhookSources.find('nope'), 'unknown source');
        Assert.isNull(WebhookSources.find(''), 'blank name');
        Assert.isNull(WebhookSources.find(null), 'null name');
    }

    @IsTest
    static void buildersConfigureASourceInMemory() {
        WebhookSources.Source source = new WebhookSources.Source('Custom')
            .withSignature('X-Sig', 'v1=', WebhookSignature.Scheme.TIMESTAMP_DOT_BODY)
            .withTimestamp('X-Ts', 120)
            .withEventId('X-Id', 'id')
            .withEventType('X-Type', 'type')
            .withActive(true);
        WebhookSources.sourceOverrides = new Map<String, WebhookSources.Source>{ 'custom' => source };

        WebhookSources.Source found = WebhookSources.find('Custom');

        Assert.areEqual('X-Sig', found.signatureHeader, 'signature header');
        Assert.areEqual('v1=', found.signaturePrefix, 'prefix');
        Assert.areEqual(WebhookSignature.Scheme.TIMESTAMP_DOT_BODY, found.scheme, 'scheme');
        Assert.areEqual('X-Ts', found.timestampHeader, 'timestamp header');
        Assert.areEqual(120, found.toleranceSeconds, 'tolerance');
        Assert.areEqual('X-Id', found.eventIdHeader, 'id header');
        Assert.areEqual('id', found.eventIdPath, 'id path');
        Assert.areEqual('X-Type', found.eventTypeHeader, 'type header');
        Assert.areEqual('type', found.eventTypePath, 'type path');
        Assert.areEqual(new List<String>{ 'X-Sig', 'X-Ts', 'X-Id', 'X-Type' }, found.interestingHeaders(), 'all four headers kept');
        Assert.isNull(WebhookSources.find('Github'), 'overrides replace the metadata');

        source.withActive(false);
        Assert.isNull(WebhookSources.find('Custom'), 'inactive sources are not found');
    }

    @IsTest
    static void secretsComeFromTheProtectedCustomSetting() {
        insert new Webhook_Secret__c(Name = 'Demo', Secret__c = 'whsec_from_setting');

        Assert.areEqual('whsec_from_setting', WebhookSources.secretFor('Demo'), 'secret by source name');
        Assert.isNull(WebhookSources.secretFor('Nope'), 'no record, no secret');

        WebhookSources.secretOverrides = new Map<String, String>{ 'demo' => 'override' };
        Assert.areEqual('override', WebhookSources.secretFor('Demo'), 'test override wins');
    }
}
