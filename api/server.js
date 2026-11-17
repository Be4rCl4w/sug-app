require('dotenv').config();
const express = require('express');
const cors = require('cors');
const sql = require('mssql');
const { DefaultAzureCredential } = require('@azure/identity');

const app = express();
app.use(express.json());
app.use(cors());

const port = process.env.PORT || 3000;

// --- Cached DB pool (acquired once, reused across requests) ---
let poolPromise = null;

function getDbPool() {
    if (!poolPromise) {
        poolPromise = (async () => {
            const credential = new DefaultAzureCredential();
            const tokenResponse = await credential.getToken("https://database.windows.net/.default");

            const config = {
                server: process.env.DB_SERVER, // e.g., 'your-sql-server.database.windows.net'
                database: process.env.DB_NAME, // e.g., 'sug_db'
                options: {
                    encrypt: true,
                    trustServerCertificate: false
                },
                authentication: {
                    type: 'azure-active-directory-access-token',
                    options: {
                        token: tokenResponse.token
                    }
                },
                pool: {
                    max: 10,
                    min: 0,
                    idleTimeoutMillis: 30000
                }
            };

            const pool = await sql.connect(config);
            pool.on('error', (err) => {
                console.error('DB pool error:', err);
                poolPromise = null; // force reconnect on next request
            });
            return pool;
        })();
    }
    return poolPromise;
}

// Health check endpoint (also verifies DB reachability)
app.get('/api/health', async (req, res) => {
    try {
        const pool = await getDbPool();
        await pool.request().query('SELECT 1');
        res.status(200).json({ status: 'Healthy', institution: 'University of Nigeria, Nsukka' });
    } catch (err) {
        console.error('Health check failed:', err);
        res.status(503).json({ status: 'Unhealthy', error: 'Database unreachable' });
    }
});

// Get candidates and current vote counts
app.get('/api/candidates', async (req, res) => {
    try {
        const pool = await getDbPool();
        const result = await pool.request().query('SELECT Id, Name, Department, VoteCount FROM Candidates');
        res.json(result.recordset);
    } catch (err) {
        console.error('Error fetching candidates:', err);
        res.status(500).json({ error: 'Internal Server Error' });
    }
});

// Cast vote endpoint
app.post('/api/vote', async (req, res) => {
    const { candidateId, voterId } = req.body;

    if (!candidateId || !voterId) {
        return res.status(400).json({ error: 'Candidate ID and Voter ID/Matric Number are required.' });
    }

    // Validate the raw value BEFORE any coercion so 1.5 / '1.5' are rejected too
    const numericId = Number(candidateId);
    if (!Number.isInteger(numericId) || numericId <= 0) {
        return res.status(400).json({ error: 'Candidate ID must be a positive integer.' });
    }
    const id = numericId;

    const trimmedVoterId = String(voterId).trim();
    if (trimmedVoterId.length < 4 || trimmedVoterId.length > 50) {
        return res.status(400).json({ error: 'Invalid Voter ID/Matric Number format.' });
    }

    try {
        const pool = await getDbPool();

        // Validate the candidate exists (prevents phantom votes in VotesLog)
        const candResult = await pool.request()
            .input('candidateId', sql.Int, id)
            .query('SELECT Id FROM Candidates WHERE Id = @candidateId');

        if (candResult.recordset.length === 0) {
            return res.status(400).json({ error: 'Invalid candidate selected.' });
        }

        // Transaction: Record vote and increment counter atomically.
        // NOTE: duplicate votes must ALSO be blocked at the schema level with:
        //   ALTER TABLE VotesLog ADD CONSTRAINT UQ_VoterIdentifier UNIQUE (VoterIdentifier);
        const transaction = new sql.Transaction(pool);
        await transaction.begin();

        try {
            const request = new sql.Request(transaction);
            await request
                .input('voterId', sql.NVarChar, trimmedVoterId)
                .input('candidateId', sql.Int, id)
                .query('INSERT INTO VotesLog (VoterIdentifier, CandidateId) VALUES (@voterId, @candidateId)');

            const updateRequest = new sql.Request(transaction);
            await updateRequest
                .input('candidateId', sql.Int, id)
                .query('UPDATE Candidates SET VoteCount = VoteCount + 1 WHERE Id = @candidateId');

            await transaction.commit();
            res.status(200).json({ message: 'Vote successfully recorded for the UNN SUG Election!' });
        } catch (txErr) {
            await transaction.rollback();

            // Unique-constraint violation = voter already voted (race-safe, schema-level guard)
            if (txErr.number === 2627 || txErr.number === 2601) {
                return res.status(403).json({ error: 'Access Denied: This Matriculation Number has already recorded a vote.' });
            }
            throw txErr;
        }
    } catch (err) {
        console.error('Error processing vote:', err);
        res.status(500).json({ error: 'Internal Server Error while casting vote.' });
    }
});

module.exports = { app };

// Only start the HTTP server when run directly (node server.js), not when imported by tests
if (require.main === module) {
    app.listen(port, () => {
        console.log(`UNN SUG API running on port ${port}`);
    });
}