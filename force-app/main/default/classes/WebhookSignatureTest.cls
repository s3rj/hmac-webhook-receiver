@IsTest
private class WebhookSignatureTest {
    private static final String SECRET = 'whsec_test_secret';
    private static final Datetime NOW = Datetime.newInstance(2026, 11, 6, 12, 0, 0);

    private static WebhookSignature.Verdict bodyVerdict(String body, String header, String prefix, String secret) {
        return WebhookSignature.verify(Blob.valueOf(body), header, prefix, secret, WebhookSignature.Scheme.BODY, null, null, NOW);
    }

    @IsTest
    static void acceptsAValidBodySignature() {
        String body = '{"id":"1"}';
        String digest = WebhookSignature.hmacHex(body, SECRET);

        Assert.isTrue(bodyVerdict(body, 'sha256=' + digest, 'sha256=', SECRET).valid, 'prefixed signature accepted');
        Assert.isTrue(bodyVerdict(body, digest, null, SECRET).valid, 'bare signature accepted');
        Assert.isTrue(bodyVerdict(body, ' sha256=' + digest.toUpperCase() + ' ', 'sha256=', SECRET).valid, 'hex case and whitespace do not matter');
        Assert.areEqual(64, digest.length(), 'SHA-256 hex digest');
    }

    @IsTest
    static void rejectsTamperingWrongSecretsAndMissingPieces() {
        String body = '{"id":"1"}';
        String digest = WebhookSignature.hmacHex(body, SECRET);

        Assert.areEqual('signature mismatch', bodyVerdict('{"id":"2"}', 'sha256=' + digest, 'sha256=', SECRET).reason, 'tampered body');
        Assert.areEqual('signature mismatch', bodyVerdict(body, 'sha256=' + digest, 'sha256=', 'other').reason, 'wrong secret');
        Assert.areEqual('signature prefix mismatch', bodyVerdict(body, 'sha1=' + digest, 'sha256=', SECRET).reason, 'wrong prefix');
        Assert.areEqual('missing signature header', bodyVerdict(body, null, 'sha256=', SECRET).reason, 'no header');
        Assert.areEqual('no secret configured', bodyVerdict(body, 'sha256=' + digest, 'sha256=', null).reason, 'no secret');
        Assert.isFalse(bodyVerdict(body, 'sha256=' + digest.substring(1), 'sha256=', SECRET).valid, 'short signature');
    }

    @IsTest
    static void timestampSchemeBindsTheTimestampAndRejectsReplays() {
        String body = '{"id":"2"}';
        String ts = String.valueOf(NOW.getTime() / 1000);
        String signature = WebhookSignature.hmacHex(ts + '.' + body, SECRET);
        WebhookSignature.Scheme stamped = WebhookSignature.Scheme.TIMESTAMP_DOT_BODY;
        Blob payload = Blob.valueOf(body);

        Assert.isTrue(WebhookSignature.verify(payload, signature, null, SECRET, stamped, ts, null, NOW).valid, 'fresh delivery accepted');
        Assert.isTrue(WebhookSignature.verify(payload, signature, null, SECRET, stamped, ts, 60, NOW.addSeconds(59)).valid, 'inside a custom tolerance');

        WebhookSignature.Verdict stale = WebhookSignature.verify(payload, signature, null, SECRET, stamped, ts, null, NOW.addMinutes(10));
        Assert.isFalse(stale.valid, 'ten minutes later is a replay');
        Assert.isTrue(stale.reason.startsWith('timestamp outside tolerance'), 'reason: ' + stale.reason);
        Assert.isTrue(WebhookSignature.verify(payload, signature, null, SECRET, stamped, ts, 900, NOW.addMinutes(10)).valid, 'unless the tolerance allows it');

        String otherTs = String.valueOf(NOW.getTime() / 1000 + 5);
        Assert.areEqual('signature mismatch', WebhookSignature.verify(payload, signature, null, SECRET, stamped, otherTs, null, NOW).reason, 'timestamp is part of the signed text');
        Assert.areEqual('missing or malformed timestamp', WebhookSignature.verify(payload, signature, null, SECRET, stamped, null, null, NOW).reason, 'no timestamp');
        Assert.areEqual('missing or malformed timestamp', WebhookSignature.verify(payload, signature, null, SECRET, stamped, 'yesterday', null, NOW).reason, 'non-numeric timestamp');
        Assert.isTrue(WebhookSignature.verify(payload, signature, null, SECRET, stamped, ' ' + ts + ' ', null, NOW).valid, 'whitespace around the timestamp is tolerated');
    }

    @IsTest
    static void aRotationAcceptsThePreviousSecretAndSaysWhichOneMatched() {
        String body = '{"id":"3"}';
        Blob payload = Blob.valueOf(body);
        List<String> secrets = new List<String>{ 'rotated-secret', SECRET };
        WebhookSignature.Scheme plain = WebhookSignature.Scheme.BODY;

        WebhookSignature.Verdict current = WebhookSignature.verify(payload, WebhookSignature.hmacHex(body, 'rotated-secret'), null, secrets, plain, null, null, NOW);
        Assert.isTrue(current.valid, 'current secret accepted');
        Assert.areEqual(0, current.secretIndex, 'signed with the current secret');

        WebhookSignature.Verdict previous = WebhookSignature.verify(payload, WebhookSignature.hmacHex(body, SECRET), null, secrets, plain, null, null, NOW);
        Assert.isTrue(previous.valid, 'previous secret still accepted');
        Assert.areEqual(1, previous.secretIndex, 'signed with the previous secret');

        WebhookSignature.Verdict neither = WebhookSignature.verify(payload, WebhookSignature.hmacHex(body, 'other'), null, secrets, plain, null, null, NOW);
        Assert.isFalse(neither.valid, 'unknown secret rejected');
        Assert.areEqual('signature mismatch', neither.reason, 'reason');
        Assert.isNull(neither.secretIndex, 'no match, no index');

        Assert.areEqual('no secret configured', WebhookSignature.verify(payload, 'abc', null, new List<String>{ '', null }, plain, null, null, NOW).reason, 'blanks do not count');
        Assert.areEqual(0, bodyVerdict(body, WebhookSignature.hmacHex(body, SECRET), null, SECRET).secretIndex, 'single-secret calls report index 0');
    }

    @IsTest
    static void constantTimeEqualsHandlesEdgeCases() {
        Assert.isTrue(WebhookSignature.constantTimeEquals('abcd', 'abcd'), 'equal');
        Assert.isFalse(WebhookSignature.constantTimeEquals('abcd', 'abce'), 'last char differs');
        Assert.isFalse(WebhookSignature.constantTimeEquals('abcd', 'bbcd'), 'first char differs');
        Assert.isFalse(WebhookSignature.constantTimeEquals('abcd', 'abc'), 'length differs');
        Assert.isFalse(WebhookSignature.constantTimeEquals(null, 'abc'), 'null left');
        Assert.isFalse(WebhookSignature.constantTimeEquals('abc', null), 'null right');
        Assert.isTrue(WebhookSignature.constantTimeEquals('', ''), 'empty');
    }

    @IsTest
    static void schemeNamesMapToSchemes() {
        Assert.areEqual(WebhookSignature.Scheme.TIMESTAMP_DOT_BODY, WebhookSignature.schemeFor('TimestampDotBody'), 'timestamp scheme');
        Assert.areEqual(WebhookSignature.Scheme.BODY, WebhookSignature.schemeFor('Body'), 'body scheme');
        Assert.areEqual(WebhookSignature.Scheme.BODY, WebhookSignature.schemeFor(null), 'default');
    }
}
