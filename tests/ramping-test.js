import http from 'k6/http';
import { check } from 'k6';

const pdf = open('./cetonic_regime.pdf', 'b');

export const options = {
  scenarios: {
    extract: {
      executor: 'ramping-vus',

      startVUs: 1,

      stages: [
        { duration: '10s', target: 1 },  // baseline
        { duration: '20s', target: 2 },  // 2 requêtes concurrentes
        { duration: '20s', target: 5 },  // 5
        { duration: '20s', target: 10 }, // 10
        { duration: '20s', target: 20 }, // 20
        { duration: '10s', target: 0 },  // arrêt progressif
      ],

      gracefulRampDown: '5s',
    },
  },

  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<30000'],
  },
};

export default function () {
  const response = http.post(
    'http://127.0.0.1:8085/extract',
    {
      files: http.file(
        pdf,
        'cetonic_regime.pdf',
        'application/pdf'
      ),
    },
    {
      headers: {
        Accept: 'application/json',
      },
      timeout: '2m',
    }
  );

  check(response, {
    'HTTP 200': (r) => r.status === 200,
  });
}