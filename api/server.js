const express = require('express');
const cors = require('cors');
const sql = require('mssql');
const { DefaultAzureCredential } = require('@azure/identity');

const app = express();
app.use(express.json());
app.use(cors());

const port = process.env.PORT || 3000;

// Connect to Azure SQL using Azure Managed Identity token
async function getDbConnection() {
    try {
        const credential = new DefaultAzureCredential();
        const tokenResponse = await credential.getToken("https://database.windows.net/.default");

        const config = {
            server: process.env.DB_SERVER, // e.g., 'your-sql-server.database.windows.net'
            database: process.env.DB_NAME, // e.g., 'sug_db'
            options: {
                encrypt: true,
                enableArithAbort: true,
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

        let pool = await sql.connect(config);
        return pool;
    } catch (err) {
        console.error('Database token/connection error:', err);
        throw err;
    }
}

// Health check endpoint
app.get('/api/health', (req, res) => {
    res.status(200).json({ status: 'Healthy', institution: 'University of Nigeria, Nsukka' });
});

// Get candidates and current vote counts
app.get('/api/candidates', async (req, res) => {
    try {
        const pool = await getDbConnection();
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

    try {
        const pool = await getDbConnection();

        // Check if voter has already voted
        const checkResult = await pool.request()
            .input('voterId', sql.NVarChar, voterId.trim())
            .query('SELECT Id FROM VotesLog WHERE VoterIdentifier = @voterId');

        if (checkResult.recordset.length > 0) {
            return res.status(403).json({ error: 'Access Denied: This Matriculation Number has already recorded a vote.' });
        }

        // Transaction: Record vote and increment counter atomically
        const transaction = new sql.Transaction(pool);
        await transaction.begin();

        try {
            const request = new sql.Request(transaction);
            await request
                .input('voterId', sql.NVarChar, voterId.trim())
                .input('candidateId', sql.Int, candidateId)
                .query('INSERT INTO VotesLog (VoterIdentifier, CandidateId) VALUES (@voterId, @candidateId)');

            const updateRequest = new sql.Request(transaction);
            await updateRequest
                .input('candidateId', sql.Int, candidateId)
                .query('UPDATE Candidates SET VoteCount = VoteCount + 1 WHERE Id = @candidateId');

            await transaction.commit();
            res.status(200).json({ message: 'Vote successfully recorded for the UNN SUG Election!' });
        } catch (txErr) {
            await transaction.rollback();
            throw txErr;
        }
    } catch (err) {
        console.error('Error processing vote:', err);
        res.status(500).json({ error: 'Internal Server Error while casting vote.' });
    }
});

app.listen(port, () => {
    console.log(`UNN SUG API running on port ${port}`);
});