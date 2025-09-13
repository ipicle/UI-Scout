#!/usr/bin/env node

const http = require('http');
const { exec } = require('child_process');

async function startUIScoutService() {
    return new Promise((resolve, reject) => {
        console.log('Starting UI Scout service...');
        const service = exec('./cli-tool serve --port 3847', (error, stdout, stderr) => {
            if (error) {
                reject(error);
                return;
            }
        });
        
        // Wait a moment for service to start
        setTimeout(resolve, 2000);
    });
}

async function makeRequest(endpoint, method = 'GET', data = null) {
    return new Promise((resolve, reject) => {
        const options = {
            hostname: 'localhost',
            port: 3847,
            path: endpoint,
            method: method,
            headers: {
                'Content-Type': 'application/json',
            }
        };
        
        const req = http.request(options, (res) => {
            let body = '';
            res.on('data', (chunk) => {
                body += chunk;
            });
            
            res.on('end', () => {
                try {
                    resolve(JSON.parse(body));
                } catch (e) {
                    resolve(body);
                }
            });
        });
        
        req.on('error', (err) => {
            reject(err);
        });
        
        if (data) {
            req.write(JSON.stringify(data));
        }
        
        req.end();
    });
}

async function demonstrateUIScout() {
    try {
        console.log('=== UI Scout Integration Example ===\n');
        
        // Start the service (in production this would already be running)
        await startUIScoutService();
        
        console.log('1. Discovering UI elements...');
        const elements = await makeRequest('/discover');
        console.log(`   Found ${elements.elements ? elements.elements.length : 0} elements\n`);
        
        console.log('2. Finding specific element...');
        const findResult = await makeRequest('/find', 'POST', {
            query: 'submit button',
            confidence_threshold: 0.7
        });
        console.log('   Best match:', findResult.element ? findResult.element.role : 'none found\n');
        
        console.log('3. Getting element signature...');
        if (findResult.element) {
            const signature = await makeRequest('/signature', 'POST', {
                element_id: findResult.element.id
            });
            console.log('   Signature generated:', signature.success ? 'yes' : 'no\n');
        }
        
        console.log('4. Testing performance...');
        const start = Date.now();
        for (let i = 0; i < 5; i++) {
            await makeRequest('/discover');
        }
        const duration = Date.now() - start;
        console.log(`   5 discovery calls took ${duration}ms (avg: ${duration/5}ms)\n`);
        
        console.log('=== Integration Complete ===');
        console.log('UI Scout is ready for AI assistant integration!');
        
    } catch (error) {
        console.error('Error:', error.message);
        console.log('\nNote: Make sure to build the project first:');
        console.log('  make build');
        console.log('  make install');
    }
}

// Handle graceful shutdown
process.on('SIGINT', () => {
    console.log('\nShutting down...');
    process.exit(0);
});

demonstrateUIScout();
