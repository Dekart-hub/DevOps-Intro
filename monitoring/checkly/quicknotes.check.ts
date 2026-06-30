import { ApiCheck, AssertionBuilder, Frequency } from 'checkly/constructs'

// Public URL of your QuickNotes tunnel, e.g. a cloudflared trycloudflare.com
// address. It is read from the environment so the (ephemeral) URL is never
// committed:  export QUICKNOTES_URL=https://your-tunnel.trycloudflare.com
const url = process.env.QUICKNOTES_URL
if (!url) {
  throw new Error('Set QUICKNOTES_URL to your public QuickNotes URL before running checkly.')
}

// A robot probe that polls /health from two regions every minute and alerts
// if the response is not 200 or is slower than 2 seconds.
new ApiCheck('quicknotes-health', {
  name: 'QuickNotes /health',
  activated: true,
  // Every 1 minute, from Frankfurt + Singapore (two distinct regions).
  frequency: Frequency.EVERY_1M,
  locations: ['eu-central-1', 'ap-southeast-1'],
  // Alert if the request takes longer than 2s; warn (degraded) past 1s.
  degradedResponseTime: 1000,
  maxResponseTime: 2000,
  request: {
    method: 'GET',
    url: `${url}/health`,
    assertions: [
      // Alert if the status code is not 200.
      AssertionBuilder.statusCode().equals(200),
      // QuickNotes /health returns {"status":"ok","notes":N}.
      AssertionBuilder.jsonBody('$.status').equals('ok'),
    ],
  },
})
