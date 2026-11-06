/**
 * HMAC-SHA256 verification for webhook deliveries.
 *
 * Two signing schemes cover most senders: the raw body (GitHub, Shopify, many SaaS tools) and
 * "<unix timestamp>.<body>" (Stripe and the tools that copied it), where the timestamp also bounds replays.
 * The comparison is constant-time so a byte-by-byte mismatch cannot be timed.
 */
public with sharing class WebhookSignature {
    public static final Integer DEFAULT_TOLERANCE_SECONDS = 300;

    public enum Scheme {
        BODY,
        TIMESTAMP_DOT_BODY
    }

    public class Verdict {
        public Boolean valid { get; private set; }
        /** Short, safe reason for the log; never echoed to the sender. */
        public String reason { get; private set; }

        public Verdict(Boolean valid, String reason) {
            this.valid = valid;
            this.reason = reason;
        }
    }

    /**
     * @param body        the raw request body
     * @param header      the signature header value as received (may carry a prefix such as "sha256=")
     * @param prefix      the expected prefix, or null/blank
     * @param secret      the shared secret
     * @param signingScheme what the sender signed
     * @param timestamp   the timestamp header value (seconds since epoch) for TIMESTAMP_DOT_BODY, else null
     * @param tolerance   allowed clock skew in seconds, null for the default
     * @param now         the current time, injectable for tests
     */
    public static Verdict verify(Blob body, String header, String prefix, String secret, Scheme signingScheme, String timestamp, Integer tolerance, Datetime now) {
        if (String.isBlank(secret)) {
            return new Verdict(false, 'no secret configured');
        }
        if (String.isBlank(header)) {
            return new Verdict(false, 'missing signature header');
        }
        String presented = header.trim();
        if (String.isNotBlank(prefix)) {
            if (!presented.startsWith(prefix)) {
                return new Verdict(false, 'signature prefix mismatch');
            }
            presented = presented.substring(prefix.length());
        }
        String signed;
        if (signingScheme == Scheme.TIMESTAMP_DOT_BODY) {
            if (String.isBlank(timestamp) || !timestamp.trim().isNumeric()) {
                return new Verdict(false, 'missing or malformed timestamp');
            }
            Long skew = Math.abs(now.getTime() / 1000 - Long.valueOf(timestamp.trim()));
            Integer window = tolerance == null ? DEFAULT_TOLERANCE_SECONDS : tolerance;
            if (skew > window) {
                return new Verdict(false, 'timestamp outside tolerance (' + skew + 's)');
            }
            signed = timestamp.trim() + '.' + (body == null ? '' : body.toString());
        } else {
            signed = body == null ? '' : body.toString();
        }
        String expected = hmacHex(signed, secret);
        if (!constantTimeEquals(expected, presented.toLowerCase())) {
            return new Verdict(false, 'signature mismatch');
        }
        return new Verdict(true, null);
    }

    /** Lower-case hex HMAC-SHA256 of the text with the secret. */
    public static String hmacHex(String text, String secret) {
        return EncodingUtil.convertToHex(Crypto.generateMac('hmacSHA256', Blob.valueOf(text), Blob.valueOf(secret)));
    }

    /** Compares two strings in time that depends only on their length, not on where they differ. */
    public static Boolean constantTimeEquals(String a, String b) {
        if (a == null || b == null || a.length() != b.length()) {
            return false;
        }
        Integer diff = 0;
        for (Integer i = 0; i < a.length(); i++) {
            diff = diff | (a.charAt(i) ^ b.charAt(i));
        }
        return diff == 0;
    }

    public static Scheme schemeFor(String name) {
        return name == 'TimestampDotBody' ? Scheme.TIMESTAMP_DOT_BODY : Scheme.BODY;
    }
}
